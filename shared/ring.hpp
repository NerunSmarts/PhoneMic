#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace pm {
// Exactly one producer and one consumer. Neither side allocates or locks.
// Only the consumer may discard old data; the producer never overwrites it.
template <size_t Capacity> class Ring {
    std::array<float, Capacity> data_{};
    alignas(64) std::atomic<uint64_t> write_{0};
    alignas(64) std::atomic<uint64_t> read_{0};
public:
    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    size_t available() const {
        // Observational only, also safe from a third diagnostics thread.
        auto r = read_.load(std::memory_order_acquire);
        auto w = write_.load(std::memory_order_acquire);
        return w >= r ? std::min<uint64_t>(w - r, Capacity) : 0;
    }
    bool push(const float* src, size_t n) {
        auto w = write_.load(std::memory_order_relaxed);
        auto r = read_.load(std::memory_order_acquire);
        if (n > Capacity - (w - r)) return false;
        for (size_t i = 0; i < n; ++i) data_[(w + i) % Capacity] = src[i];
        write_.store(w + n, std::memory_order_release); return true;
    }
    size_t pop(float* dst, size_t n) {
        auto r = read_.load(std::memory_order_relaxed);
        auto w = write_.load(std::memory_order_acquire);
        n = std::min<uint64_t>(n, w - r);
        for (size_t i = 0; i < n; ++i) dst[i] = data_[(r + i) % Capacity];
        read_.store(r + n, std::memory_order_release); return n;
    }
    void trim(size_t keep) {
        auto r = read_.load(std::memory_order_relaxed);
        auto w = write_.load(std::memory_order_acquire);
        if (w - r > keep) read_.store(w - keep, std::memory_order_release);
    }
};
}
