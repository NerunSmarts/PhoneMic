#import "AudioBridge.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "protocol.hpp"
#include "ring.hpp"
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <thread>

namespace {
uint64_t nowNS() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
struct Sender {
    pm::Ring<4800> ring;
    AudioUnit unit = nullptr;
    std::array<float, 8192> capture{};
    int fd = -1;
    uint64_t token = 0;
    std::atomic<bool> running{false};
    std::thread worker;
    std::atomic<float> peak{0};
    std::atomic<uint32_t> drops{0}, packets{0}, audioErrors{0}, sendErrors{0};
    std::atomic<uint32_t> queueFrames{0}, underruns{0}, gaps{0}, late{0}, quantum{0}, received{0};
    std::atomic<uint64_t> pongNS{0};
    std::atomic<double> rttMS{0};
    ~Sender() {
        // Stop audio first: capture callback must finish before storage dies.
        if (unit) { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); }
        running = false;
        if (worker.joinable()) worker.join();
        if (fd >= 0) close(fd);
    }
    static OSStatus input(void* context, AudioUnitRenderActionFlags* flags,
                          const AudioTimeStamp* time, UInt32, UInt32 n, AudioBufferList*) {
        auto& s = *static_cast<Sender*>(context);
        if (n > s.capture.size()) { ++s.audioErrors; return kAudio_ParamError; }
        AudioBufferList list{}; list.mNumberBuffers = 1;
        list.mBuffers[0] = {1, UInt32(n * sizeof(float)), s.capture.data()};
        OSStatus result = AudioUnitRender(s.unit, flags, time, 1, n, &list);
        if (result) { ++s.audioErrors; return result; }
        float peak = 0;
        for (UInt32 i = 0; i < n; ++i) peak = std::max(peak, std::abs(s.capture[i]));
        s.peak.store(peak, std::memory_order_relaxed);
        if (!s.ring.push(s.capture.data(), n)) ++s.drops;
        return noErr;
    }
    void run() {
        std::array<float, pm::frames> samples{};
        std::array<uint8_t, pm::packetSize> packet{};
        std::array<uint8_t, pm::packetSize + 1> response{};
        uint32_t sequence = arc4random();
        uint64_t lastPing = 0;
        while (running.load(std::memory_order_relaxed)) {
            // Discard stale capture if the network thread was descheduled.
            if (ring.available() > pm::frames * 4) {
                size_t skip = ((ring.available() - pm::frames) / pm::frames) * pm::frames;
                ring.trim(ring.available() - skip); sequence += uint32_t(skip / pm::frames); ++drops;
            }
            if (ring.available() >= pm::frames) {
                ring.pop(samples.data(), samples.size());
                pm::encode(packet.data(), {pm::Type::audio, token, sequence++, nowNS()});
                for (size_t i = 0; i < pm::frames; ++i) {
                    float value = std::isfinite(samples[i]) ? std::clamp(samples[i], -1.0f, 0.999969f) : 0;
                    uint16_t bits = uint16_t(int16_t(std::lround(value * 32768)));
                    packet[32 + 2 * i] = bits & 255; packet[33 + 2 * i] = bits >> 8;
                }
                if (send(fd, packet.data(), packet.size(), 0) == ssize_t(packet.size())) ++packets;
                else ++sendErrors;
            }
            uint64_t now = nowNS();
            if (now - lastPing > 500000000) {
                std::array<uint8_t, pm::headerSize> ping{};
                pm::encode(ping.data(), {pm::Type::ping, token, 0, now});
                send(fd, ping.data(), ping.size(), 0); lastPing = now;
            }
            for (int i = 0; i < 8; ++i) {
                ssize_t n = recv(fd, response.data(), response.size(), 0);
                if (n < 0) break;
                pm::Header h{};
                if (pm::decode(response.data(), size_t(n), h) && h.type == pm::Type::pong &&
                    h.token == token && h.time == lastPing && now >= h.time) {
                    rttMS = double(now - h.time) / 1e6; pongNS = now;
                    queueFrames = pm::get32(response.data() + 32);
                    underruns = pm::get32(response.data() + 36); gaps = pm::get32(response.data() + 40);
                    late = pm::get32(response.data() + 44); quantum = pm::get32(response.data() + 48);
                    received = pm::get32(response.data() + 52);
                }
            }
            if (ring.available() < pm::frames) std::this_thread::sleep_for(std::chrono::microseconds(500));
        }
    }
};
NSError* failure(NSString* message, NSInteger code = -1) {
    return [NSError errorWithDomain:@"PhoneMic" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
}

@implementation AudioBridge {
    std::unique_ptr<Sender> _sender;
    double _inputMS, _bufferMS;
}
- (BOOL)startWithHost:(NSString*)host port:(uint16_t)port token:(uint64_t)token error:(NSError**)error {
    [self stop];
    auto s = std::make_unique<Sender>();
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(port);
    if (!token || !port || inet_pton(AF_INET, host.UTF8String, &address.sin_addr) != 1) {
        if (error) *error = failure(@"Enter the PC's Wi-Fi IPv4 address, port, and 16-digit pairing code.");
        return NO;
    }
    s->fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (s->fd < 0) { if (error) *error = failure(@"Cannot create the network socket."); return NO; }
    unsigned interface = if_nametoindex("en0");
    if (!interface || setsockopt(s->fd, IPPROTO_IP, IP_BOUND_IF, &interface, sizeof(interface)) < 0) {
        if (error) *error = failure(@"Connect the iPhone to Wi-Fi first."); return NO;
    }
    int sendBuffer = 8192;
    setsockopt(s->fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, sizeof(sendBuffer));
    if (connect(s->fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0 ||
        fcntl(s->fd, F_SETFL, O_NONBLOCK) < 0) {
        if (error) *error = failure(@"Cannot reach this address over Wi-Fi."); return NO;
    }
    s->token = token;
    AVAudioSession* session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeMeasurement options:0 error:error] ||
        ![session setPreferredSampleRate:48000 error:error] ||
        ![session setPreferredIOBufferDuration:0.005 error:error] ||
        ![session setActive:YES error:error]) return NO;
    // Keep Bluetooth processing / latency out of the signal path.
    for (AVAudioSessionPortDescription* input in session.availableInputs) {
        if ([input.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            if (![session setPreferredInput:input error:error]) {
                [session setActive:NO error:nil]; return NO;
            }
            break;
        }
    }
    _inputMS = session.inputLatency * 1000; _bufferMS = session.IOBufferDuration * 1000;
    AudioComponentDescription desc{};
    desc.componentType = kAudioUnitType_Output; desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    OSStatus status = component ? AudioComponentInstanceNew(component, &s->unit) : kAudio_ParamError;
    auto check = [&](OSStatus result) { if (!status) status = result; };
    if (!status) {
        UInt32 one = 1, zero = 0, maxFrames = UInt32(s->capture.size());
        check(AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof(one)));
        check(AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, sizeof(zero)));
        AudioStreamBasicDescription format{};
        format.mSampleRate = pm::rate; format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
        format.mBytesPerPacket = format.mBytesPerFrame = sizeof(float);
        format.mFramesPerPacket = 1; format.mChannelsPerFrame = 1; format.mBitsPerChannel = 32;
        check(AudioUnitSetProperty(s->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format)));
        check(AudioUnitSetProperty(s->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames)));
        AURenderCallbackStruct callback{Sender::input, s.get()};
        check(AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &callback, sizeof(callback)));
        if (!status) status = AudioUnitInitialize(s->unit);
        if (!status) status = AudioOutputUnitStart(s->unit);
    }
    if (status) {
        if (error) *error = failure([NSString stringWithFormat:@"Microphone setup failed (%d).", int(status)], status);
        s.reset(); [session setActive:NO error:nil]; return NO;
    }
    s->running = true;
    Sender* ptr = s.get();
    s->worker = std::thread([ptr] {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        ptr->run();
    });
    _sender = std::move(s);
    return YES;
}
- (void)stop {
    if (_sender) {
        _sender.reset();
        [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }
}
- (NSDictionary<NSString*, NSNumber*>*)snapshot {
    if (!_sender) return @{};
    auto& s = *_sender;
    uint64_t pong = s.pongNS.load();
    return @{@"peak": @(s.peak.load()), @"packets": @(s.packets.load()), @"drops": @(s.drops.load()),
             @"audioErrors": @(s.audioErrors.load()), @"sendErrors": @(s.sendErrors.load()),
             @"connected": @(pong && nowNS() - pong < 3000000000ULL), @"rtt": @(s.rttMS.load()),
             @"queue": @(s.queueFrames.load() / 48.0), @"quantum": @(s.quantum.load()),
             @"underruns": @(s.underruns.load()), @"gaps": @(s.gaps.load()), @"late": @(s.late.load()),
             @"received": @(s.received.load()), @"input": @(_inputMS), @"buffer": @(_bufferMS)};
}
@end
