#include "playout.hpp"
#include <cstdlib>
#include <iostream>
#include <thread>
#include <vector>

#define CHECK(x) do { if (!(x)) { std::cerr << __FILE__ << ':' << __LINE__ << ": " #x " failed\n"; std::exit(1); } } while (0)
static std::array<uint8_t, pm::frames * 2> pcm() {
    std::array<uint8_t, pm::frames * 2> data{};
    for (size_t i = 0; i < pm::frames; ++i) { data[i * 2] = 0; data[i * 2 + 1] = 32; }
    return data;
}
static void protocol() {
    std::array<uint8_t, pm::packetSize + 1> data{};
    pm::Header h{pm::Type::audio, 0x0123456789abcdefULL, 0xfffffffe, 0xfedcba9876543210ULL}, parsed{};
    pm::encode(data.data(), h);
    CHECK(data[8] == 0x01 && data[15] == 0xef && data[16] == 0xff);
    CHECK(pm::decode(data.data(), pm::packetSize, parsed));
    CHECK(parsed.token == h.token && parsed.sequence == h.sequence && parsed.time == h.time);
    for (size_t n = 0; n < pm::packetSize; ++n) CHECK(!pm::decode(data.data(), n, parsed));
    CHECK(!pm::decode(data.data(), data.size(), parsed));
    data[4] = 2; CHECK(!pm::decode(data.data(), pm::packetSize, parsed)); data[4] = 1;
    data[5] = 255; CHECK(!pm::decode(data.data(), pm::packetSize, parsed));
    h.type = pm::Type::ping; pm::encode(data.data(), h);
    CHECK(pm::decode(data.data(), 32, parsed));
    CHECK(!pm::decode(data.data(), 56, parsed));
    h.type = pm::Type::pong; pm::encode(data.data(), h);
    CHECK(pm::decode(data.data(), 56, parsed));
    const uint8_t low[] = {0, 128}, high[] = {255, 127};
    CHECK(pm::sample(low) == -1 && pm::sample(high) > 0.999f);
}
static void ring() {
    pm::Ring<4> queue;
    float in[] = {1, 2, 3, 4}, out[4]{};
    CHECK(queue.push(in, 4)); CHECK(!queue.push(in, 1));
    CHECK(queue.pop(out, 2) == 2 && out[0] == 1 && out[1] == 2);
    CHECK(queue.push(in, 2));
    CHECK(queue.pop(out, 4) == 4 && out[0] == 3 && out[1] == 4 && out[2] == 1 && out[3] == 2);
    CHECK(queue.push(in, 4)); queue.trim(2);
    CHECK(queue.pop(out, 4) == 2 && out[0] == 3);
    pm::Ring<1024> concurrent;
    std::thread producer([&] {
        for (int i = 0; i < 200000; ++i) { float f = float(i); while (!concurrent.push(&f, 1)) std::this_thread::yield(); }
    });
    for (int i = 0; i < 200000; ++i) {
        float f; while (!concurrent.pop(&f, 1)) std::this_thread::yield(); CHECK(f == float(i));
    }
    producer.join(); CHECK(concurrent.available() == 0);
}
static void playout() {
    auto data = pcm(); pm::Playout p(480); std::array<float, 128> out;
    p.render(out.data(), out.size()); CHECK(out[0] == 0 && p.underruns == 0);
    p.receive(0xfffffffe, data.data()); p.receive(0xffffffff, data.data()); p.receive(0, data.data());
    p.render(out.data(), out.size()); CHECK(out[64] == 0.25f);
    p.receive(2, data.data()); CHECK(p.lost == 1);
    p.receive(1, data.data()); CHECK(p.late == 1);
    for (int i = 0; i < 40; ++i) p.render(out.data(), out.size());
    CHECK(p.underruns == 1 && out[0] == 0);
    for (uint32_t i = 3; i < 100; ++i) p.receive(i, data.data());
    p.render(out.data(), out.size()); CHECK(p.trims >= 1 && p.queued() <= 608);
    p.newSession(); p.receive(42, data.data()); CHECK(p.late == 1);
}
static void drift(double inputRate) {
    auto data = pcm(); pm::Playout p(480); std::array<float, 128> out;
    uint32_t sequence = 0; double input = 0;
    // Three minutes of different device clocks; no wall-clock waiting.
    for (int i = 0; i < 67500; ++i) {
        input += 128 * inputRate;
        while (input >= 240) { p.receive(sequence++, data.data()); input -= 240; }
        p.render(out.data(), out.size());
        CHECK(p.queued() < 2000);
    }
    CHECK(p.underruns <= 2); CHECK(p.trims == 0);
}
int main() {
    protocol(); ring(); playout(); drift(1.0002); drift(0.9998);
    std::cout << "Protocol validation, concurrent SPSC, loss/wrap/recovery, and ±200 ppm drift passed.\n";
}
