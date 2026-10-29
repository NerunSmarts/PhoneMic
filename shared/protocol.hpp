#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace pm {
constexpr uint32_t rate = 48000;
constexpr size_t frames = 240, headerSize = 32, packetSize = headerSize + frames * 2;
enum class Type : uint8_t { audio = 1, ping = 2, pong = 3 };
inline void put16(uint8_t* p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
inline void put32(uint8_t* p, uint32_t v) { for (int i = 3; i >= 0; --i) { p[i] = v; v >>= 8; } }
inline void put64(uint8_t* p, uint64_t v) { for (int i = 7; i >= 0; --i) { p[i] = v; v >>= 8; } }
inline uint16_t get16(const uint8_t* p) { return uint16_t(p[0]) << 8 | p[1]; }
inline uint32_t get32(const uint8_t* p) { uint32_t v = 0; for (int i = 0; i < 4; ++i) v = v << 8 | p[i]; return v; }
inline uint64_t get64(const uint8_t* p) { uint64_t v = 0; for (int i = 0; i < 8; ++i) v = v << 8 | p[i]; return v; }
struct Header { Type type; uint64_t token; uint32_t sequence; uint64_t time; };
inline void encode(uint8_t* p, Header h) {
    std::memcpy(p, "PMIC", 4); p[4] = 1; p[5] = uint8_t(h.type);
    put16(p + 6, h.type == Type::audio ? frames : 0);
    put64(p + 8, h.token); put32(p + 16, h.sequence);
    put32(p + 20, rate); put64(p + 24, h.time);
}
inline bool decode(const uint8_t* p, size_t n, Header& h) {
    if (n < headerSize || std::memcmp(p, "PMIC", 4) || p[4] != 1 || get32(p + 20) != rate) return false;
    h = {Type(p[5]), get64(p + 8), get32(p + 16), get64(p + 24)};
    switch (h.type) {
    case Type::audio: return n == packetSize && get16(p + 6) == frames;
    case Type::ping: return n == headerSize && get16(p + 6) == 0;
    case Type::pong: return n == headerSize + 24 && get16(p + 6) == 0;
    }
    return false;
}
inline float sample(const uint8_t* p) {
    const uint16_t bits = uint16_t(p[0]) | uint16_t(p[1]) << 8;
    return (bits < 32768 ? int32_t(bits) : int32_t(bits) - 65536) / 32768.0f;
}
}
