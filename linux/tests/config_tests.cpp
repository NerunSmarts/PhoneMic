#include "config.hpp"
#include <iostream>
#include <unistd.h>

#define CHECK(x) do { if (!(x)) { std::cerr << __LINE__ << ": " #x " failed\n"; std::exit(1); } } while (0)
template<class F> static void rejects(F action, const std::string& message) {
    try { action(); }
    catch (const std::exception& error) { CHECK(std::string(error.what()).find(message) != std::string::npos); return; }
    CHECK(false);
}
int main() {
    pm::ReceiverConfig config;
    std::istringstream input("# comment\r\n pairing_code = 00AB12ef # fixed\r\nport=6000\n jitter_ms=5\nbind_address=192.168.1.170\n");
    pm::readConfig(input, config);
    CHECK(config.token == 0xab12ef && config.port == 6000 && config.jitter == 5 && config.bindAddress == "192.168.1.170");
    auto serialized = pm::formatConfig(config);
    CHECK(serialized.find("pairing_code=00ab12ef") != std::string::npos);
    pm::ReceiverConfig restored;
    std::istringstream roundtrip(serialized); pm::readConfig(roundtrip, restored);
    CHECK(pm::formatConfig(restored) == serialized);
    for (const auto& text : {"jitter_ms=4", "jitter_ms=41", "port=0", "port=+5555", "port=65536", "port=5555oops",
                             "pairing_code=00000000", "pairing_code=123", "pairing_code=zzzzzzzz",
                             "pairing_cod=12345678", "bind_address=300.1.1.1", "bind_address=192.168.1.1.",
                             "bind_address=192.168.01.1", "missing equals", "port=5555\nport=6000"}) {
        rejects([&] { pm::ReceiverConfig bad; std::istringstream stream(text); pm::readConfig(stream, bad); }, "Config line");
    }
    char directory[] = "/tmp/phonemic-config-XXXXXX";
    CHECK(mkdtemp(directory));
    const auto path = std::string(directory) + "/receiver.conf";
    { std::ofstream file(path); file << serialized; }
    const auto options = pm::receiverOptions({"--port", "7000", "--config", path, "--quiet", "--jitter-ms", "20"}, "");
    CHECK(options.config.port == 7000 && options.config.jitter == 20 && options.config.token == 0xab12ef && options.quiet);
    CHECK(pm::receiverOptions({}, path).config.token == 0xab12ef);
    CHECK(pm::receiverOptions({"--no-config"}, path).config.token == 0);
    CHECK(pm::receiverOptions({}, path + ".missing").config.token == 0);
    rejects([&] { pm::receiverOptions({"--config", path + ".missing"}, ""); }, "Cannot open config");
    rejects([&] { pm::receiverOptions({"--config", path, "--no-config"}, ""); }, "either --config");
    { std::ofstream file(path); file << "port=5555\n"; }
    rejects([&] { pm::receiverOptions({}, path); }, "pairing_code");
    // A CLI code may supply the missing required field, and a failed parse does
    // not rewrite the user's settings or silently invent a new pairing code.
    CHECK(pm::receiverOptions({"--token", "0123abcd"}, path).config.token == 0x123abcd);
    std::filesystem::remove(path);
    std::filesystem::create_symlink(path + ".missing", path);
    rejects([&] { pm::receiverOptions({}, path); }, "Cannot open config");
    std::filesystem::remove_all(directory);
    std::cout << "Persistent settings, round trips, CLI precedence, and invalid config handling passed.\n";
}
