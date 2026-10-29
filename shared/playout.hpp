#pragma once
#include "protocol.hpp"
#include "ring.hpp"
#include <cmath>

namespace pm {
class Playout {
    Ring<48000> ring_;
    bool primed_ = false;
    float previous_ = 0;
    double correction_ = 0;
    bool haveSequence_ = false;
    uint32_t next_ = 0;
public:
    const size_t target;
    std::atomic<uint32_t> lost{0}, late{0}, underruns{0}, trims{0}, received{0};
    explicit Playout(size_t jitterFrames) : target(jitterFrames) {}
    // Network producer: conceal short gaps immediately. Late/reordered packets
    // are dropped, never held for retransmission. A long gap starts a new epoch.
    void receive(uint32_t sequence, const uint8_t* pcm) {
        if (haveSequence_) {
            int32_t delta = static_cast<int32_t>(sequence - next_);
            if (delta < 0) { ++late; return; }
            if (delta > 0) {
                lost += uint32_t(delta);
                if (delta <= 4) {
                    std::array<float, frames> silence{};
                    for (int32_t i = 0; i < delta; ++i) ring_.push(silence.data(), frames);
                }
            }
        }
        haveSequence_ = true; next_ = sequence + 1;
        std::array<float, frames> samples;
        for (size_t i = 0; i < frames; ++i) samples[i] = sample(pcm + 2 * i);
        if (!ring_.push(samples.data(), frames)) ++trims;
        ++received;
    }
    // Called only after the old peer has been idle, from the producer thread.
    void newSession() { haveSequence_ = false; }
    size_t queued() const { return ring_.available(); }
    void render(float* dst, size_t n) {
        size_t available = ring_.available();
        // Bound delay even after a stalled graph / burst of delayed UDP packets.
        if (available > target + n + 960) {
            ring_.trim(target + n); available = ring_.available(); ++trims;
        }
        if (!primed_) {
            if (available < target + n) { std::fill_n(dst, n, 0.0f); return; }
            primed_ = true; correction_ = 0;
        }
        // Compensate independent phone/PC clocks with occasional interpolated
        // single-frame slips (bounded to 1000 ppm). No pitch-scale resampling.
        double error = double(available) - double(target + n);
        correction_ += std::clamp(error / 480000.0, -0.001, 0.001) * n;
        int adjust = correction_ >= 1 ? 1 : (correction_ <= -1 ? -1 : 0);
        if (adjust) correction_ -= adjust;
        if (adjust > 0) { float discarded; ring_.pop(&discarded, 1); }
        size_t wanted = n - (adjust < 0 && n > 1 ? 1 : 0);
        size_t got = ring_.pop(dst, wanted);
        if (got < wanted) {
            std::fill(dst + got, dst + n, 0.0f); primed_ = false; ++underruns;
        } else if (wanted < n) {
            dst[n - 1] = dst[n - 2];
        }
        // Smooth the rare slip boundary across a few samples.
        if (adjust && got) {
            size_t fade = std::min<size_t>(16, got);
            for (size_t i = 0; i < fade; ++i) {
                float f = float(i + 1) / float(fade);
                dst[i] = previous_ * (1 - f) + dst[i] * f;
            }
        }
        if (n) previous_ = dst[n - 1];
    }
};
}
