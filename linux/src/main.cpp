#include "playout.hpp"
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <arpa/inet.h>
#include <sys/random.h>
#include <poll.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <thread>

using Clock = std::chrono::steady_clock;
struct Receiver {
    pm::Playout audio;
    pw_main_loop* loop = nullptr;
    pw_stream* stream = nullptr;
    std::atomic<bool> running{true};
    std::atomic<uint32_t> quantum{0};
    bool failed = false;
    explicit Receiver(size_t jitter) : audio(jitter) {}
};

static void process(void* userdata) {
    auto& r = *static_cast<Receiver*>(userdata);
    auto* b = pw_stream_dequeue_buffer(r.stream);
    if (!b) return;
    auto& d = b->buffer->datas[0];
    if (d.data && d.chunk) {
        size_t capacity = d.maxsize / sizeof(float);
        size_t n = std::min<size_t>(b->requested ? b->requested : 128, capacity);
        r.quantum.store(uint32_t(n), std::memory_order_relaxed);
        r.audio.render(static_cast<float*>(d.data), n);
        d.chunk->offset = 0; d.chunk->stride = sizeof(float); d.chunk->size = n * sizeof(float);
        b->size = n;
    }
    pw_stream_queue_buffer(r.stream, b);
}
static void stateChanged(void* userdata, pw_stream_state, pw_stream_state state, const char* error) {
    auto& r = *static_cast<Receiver*>(userdata);
    if (state == PW_STREAM_STATE_ERROR) {
        std::cerr << "PipeWire: " << (error ? error : "stream error") << '\n';
        r.failed = true; pw_main_loop_quit(r.loop);
    }
}
static void quit(void* userdata, int) { pw_main_loop_quit(static_cast<Receiver*>(userdata)->loop); }

static void network(Receiver& r, int fd, uint64_t token) {
    std::array<uint8_t, pm::packetSize + 1> packet{};
    sockaddr_in peer{};
    bool paired = false;
    uint64_t udp = 0, malformed = 0, wrongCode = 0, busy = 0, replyErrors = 0;
    auto lastPeer = Clock::now(), lastPrint = Clock::now();
    while (r.running.load()) {
        pollfd pfd{fd, POLLIN, 0};
        int result = poll(&pfd, 1, 50);
        // Keep rejected traffic visible without printing pairing tokens. A UDP
        // packet reaching this socket is distinct from an authenticated stream.
        auto receiveOne = [&] {
            sockaddr_in source{}; socklen_t length = sizeof(source);
            auto n = recvfrom(fd, packet.data(), packet.size(), 0, reinterpret_cast<sockaddr*>(&source), &length);
            pm::Header h{};
            if (n < 0) return;
            ++udp;
            if (!pm::decode(packet.data(), size_t(n), h) || h.type == pm::Type::pong) { ++malformed; return; }
            if (h.token != token) { ++wrongCode; return; }
            auto now = Clock::now();
            bool same = paired && source.sin_addr.s_addr == peer.sin_addr.s_addr && source.sin_port == peer.sin_port;
            if (paired && !same && now - lastPeer < std::chrono::seconds(3)) { ++busy; return; }
            if (!same || now - lastPeer >= std::chrono::seconds(3)) {
                r.audio.newSession(); peer = source; paired = true;
                std::cout << "\nPhone connected: " << inet_ntoa(source.sin_addr) << '\n';
            }
            lastPeer = now;
            if (h.type == pm::Type::audio) r.audio.receive(h.sequence, packet.data() + pm::headerSize);
            else {
                std::array<uint8_t, pm::headerSize + 24> response{};
                h.type = pm::Type::pong; pm::encode(response.data(), h);
                pm::put32(response.data() + 32, uint32_t(r.audio.queued()));
                pm::put32(response.data() + 36, r.audio.underruns.load());
                pm::put32(response.data() + 40, r.audio.lost.load());
                pm::put32(response.data() + 44, r.audio.late.load());
                pm::put32(response.data() + 48, r.quantum.load());
                pm::put32(response.data() + 52, r.audio.received.load());
                if (sendto(fd, response.data(), response.size(), 0, reinterpret_cast<sockaddr*>(&source), length) != ssize_t(response.size())) {
                    if (replyErrors++ == 0) std::cerr << "\nUDP acknowledgement failed: " << std::strerror(errno) << '\n';
                }
            }
        };
        if (result > 0 && (pfd.revents & POLLIN)) receiveOne();
        if (Clock::now() - lastPrint >= std::chrono::seconds(2)) {
            std::cout << "\r" << (paired && Clock::now() - lastPeer < std::chrono::seconds(3) ? "Receiving" : "Waiting  ")
                      << " | queue " << std::fixed << std::setprecision(1) << r.audio.queued() / 48.0
                      << " ms | quantum " << r.quantum.load() << " | gaps " << r.audio.lost.load()
                      << " | late " << r.audio.late.load() << " | underruns " << r.audio.underruns.load()
                      << " | trims " << r.audio.trims.load()
                      << " | UDP " << udp << " | wrong-code " << wrongCode << " | malformed " << malformed
                      << " | other-sender " << busy << " | reply-errors " << replyErrors << "    " << std::flush;
            lastPrint = Clock::now();
        }
    }
}
static unsigned number(const char* value, unsigned low, unsigned high) {
    char* end = nullptr; unsigned long n = std::strtoul(value, &end, 10);
    if (!*value || *end || n < low || n > high) throw std::runtime_error("Invalid numeric option");
    return unsigned(n);
}
int main(int argc, char** argv) {
    unsigned port = 5555, jitter = 10;
    std::string bindAddress = "0.0.0.0";
    uint64_t token = 0;
    try {
        for (int i = 1; i < argc; ++i) {
            std::string arg = argv[i];
            if (arg == "--help") {
                std::cout << "PhoneMic — Wi-Fi microphone → PipeWire virtual source\n"
                          << "Usage: phonemic [--port 5555] [--jitter-ms 10] [--bind 0.0.0.0] [--token 8_HEX_DIGITS]\n"
                          << "Jitter range: 5–40 ms. Choose PhoneMic as your game's microphone.\n";
                return 0;
            }
            if (i + 1 == argc) throw std::runtime_error("Missing value for " + arg);
            const char* value = argv[++i];
            if (arg == "--port") port = number(value, 1024, 65535);
            else if (arg == "--jitter-ms") jitter = number(value, 5, 40);
            else if (arg == "--bind") bindAddress = value;
            else if (arg == "--token") {
                if (std::strlen(value) != 8 || std::strspn(value, "0123456789abcdefABCDEF") != 8)
                    throw std::runtime_error("Token must be exactly 8 hexadecimal digits");
                token = std::strtoull(value, nullptr, 16);
                if (!token) throw std::runtime_error("Token cannot be zero");
            } else throw std::runtime_error("Unknown option: " + arg);
        }
        while (!token) {
            uint32_t generated = 0;
            if (getrandom(&generated, sizeof(generated), 0) != sizeof(generated))
                throw std::runtime_error("Cannot generate pairing token");
            token = generated;
        }
        int fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (fd < 0) throw std::runtime_error("Cannot create UDP socket");
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(port);
        if (inet_pton(AF_INET, bindAddress.c_str(), &address.sin_addr) != 1 ||
            bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0) {
            close(fd); throw std::runtime_error("Cannot bind UDP address/port (already in use?)");
        }
        int receiveBuffer = 64 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, sizeof(receiveBuffer));
        pw_init(nullptr, nullptr);
        Receiver r(jitter * 48);
        r.loop = pw_main_loop_new(nullptr);
        if (!r.loop) { close(fd); throw std::runtime_error("Cannot create PipeWire loop"); }
        pw_loop_add_signal(pw_main_loop_get_loop(r.loop), SIGINT, quit, &r);
        pw_loop_add_signal(pw_main_loop_get_loop(r.loop), SIGTERM, quit, &r);
        pw_stream_events events{}; events.version = PW_VERSION_STREAM_EVENTS;
        events.process = process; events.state_changed = stateChanged;
        r.stream = pw_stream_new_simple(pw_main_loop_get_loop(r.loop), "PhoneMic",
            pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
                PW_KEY_MEDIA_ROLE, "Communication", PW_KEY_MEDIA_CLASS, "Audio/Source",
                PW_KEY_NODE_NAME, "phonemic", PW_KEY_NODE_DESCRIPTION, "PhoneMic",
                PW_KEY_NODE_VIRTUAL, "true", PW_KEY_NODE_LATENCY, "128/48000",
                "node.want-driver", "true", "node.always-process", "true", nullptr), &events, &r);
        if (!r.stream) {
            close(fd); pw_main_loop_destroy(r.loop); pw_deinit();
            throw std::runtime_error("Cannot connect to PipeWire. Is the user service running?");
        }
        uint8_t storage[1024]; spa_pod_builder builder = SPA_POD_BUILDER_INIT(storage, sizeof(storage));
        spa_audio_info_raw info{}; info.format = SPA_AUDIO_FORMAT_F32; info.rate = pm::rate;
        info.channels = 1; info.position[0] = SPA_AUDIO_CHANNEL_MONO;
        const spa_pod* params[] = {spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info)};
        int rc = pw_stream_connect(r.stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
            pw_stream_flags(PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS), params, 1);
        if (rc < 0) {
            pw_stream_destroy(r.stream); pw_main_loop_destroy(r.loop); close(fd); pw_deinit();
            throw std::runtime_error("PipeWire stream connection failed");
        }
        std::cout << "PhoneMic receiver — UDP listening on " << bindAddress << ":" << port << "\nPairing code: "
                  << std::hex << std::setfill('0') << std::setw(8) << token << std::dec << std::setfill(' ')
                  << "\nJitter target: " << jitter << " ms. Find this PC's LAN IP with: hostname -I\n"
                  << "Select PhoneMic in your game/audio settings. Ctrl-C stops it.\n";
        std::thread worker(network, std::ref(r), fd, token);
        pw_main_loop_run(r.loop);
        r.running = false; worker.join(); close(fd);
        pw_stream_destroy(r.stream); pw_main_loop_destroy(r.loop); pw_deinit();
        std::cout << '\n'; return r.failed ? 1 : 0;
    } catch (const std::exception& e) { std::cerr << "PhoneMic: " << e.what() << '\n'; return 1; }
}
