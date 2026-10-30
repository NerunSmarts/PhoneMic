#pragma once
#include <charconv>
#include <cstdlib>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace pm {
struct ReceiverConfig {
    unsigned port = 5555;
    unsigned jitter = 10;
    std::string bindAddress = "0.0.0.0";
    uint64_t token = 0;
};
inline std::string trim(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    return value.substr(first, value.find_last_not_of(" \t\r\n") - first + 1);
}
inline unsigned configNumber(const std::string& value, unsigned low, unsigned high) {
    unsigned n = 0;
    const auto result = std::from_chars(value.data(), value.data() + value.size(), n);
    if (value.empty() || result.ec != std::errc{} || result.ptr != value.data() + value.size() || n < low || n > high)
        throw std::runtime_error("Expected a number from " + std::to_string(low) + " to " + std::to_string(high));
    return n;
}
inline bool validBindAddress(const std::string& value) {
    std::istringstream stream(value);
    std::string part;
    unsigned count = 0;
    try {
        while (std::getline(stream, part, '.')) {
            if (++count > 4 || (part.size() > 1 && part.front() == '0')) return false;
            configNumber(part, 0, 255);
        }
    } catch (const std::exception&) { return false; }
    return count == 4 && !value.empty() && value.back() != '.';
}
inline void setConfig(ReceiverConfig& config, const std::string& key, const std::string& value) {
    if (key == "port") config.port = configNumber(value, 1024, 65535);
    else if (key == "jitter_ms") config.jitter = configNumber(value, 5, 40);
    else if (key == "bind_address") {
        if (!validBindAddress(value)) throw std::runtime_error("Expected an IPv4 bind address");
        config.bindAddress = value;
    } else if (key == "pairing_code") {
        if (value.size() != 8 || value.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos)
            throw std::runtime_error("Pairing code must be exactly 8 hexadecimal digits");
        config.token = std::stoull(value, nullptr, 16);
        if (!config.token) throw std::runtime_error("Pairing code cannot be 00000000");
    } else throw std::runtime_error("Unknown setting: " + key);
}
inline void readConfig(std::istream& input, ReceiverConfig& config) {
    std::string line;
    size_t lineNumber = 0;
    std::set<std::string> seen;
    while (std::getline(input, line)) {
        ++lineNumber;
        line = trim(line.substr(0, line.find_first_of("#;")));
        if (line.empty()) continue;
        try {
            const auto equals = line.find('=');
            if (equals == std::string::npos) throw std::runtime_error("Expected setting=value");
            const auto key = trim(line.substr(0, equals));
            if (!seen.insert(key).second) throw std::runtime_error("Duplicate setting: " + key);
            setConfig(config, key, trim(line.substr(equals + 1)));
        } catch (const std::exception& error) {
            throw std::runtime_error("Config line " + std::to_string(lineNumber) + ": " + error.what());
        }
    }
    if (input.bad()) throw std::runtime_error("Cannot read configuration");
}
inline std::string formatConfig(const ReceiverConfig& config) {
    std::ostringstream out;
    out << "# PhoneMic receiver settings. Restart the service after editing.\n"
        << "pairing_code=" << std::hex << std::setfill('0') << std::setw(8) << config.token << std::dec
        << "\nport=" << config.port << "\njitter_ms=" << config.jitter << "\nbind_address=" << config.bindAddress << '\n';
    return out.str();
}
inline std::string defaultConfigPath() {
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    if (xdg && xdg[0] == '/') return std::string(xdg) + "/phonemic/receiver.conf";
    const char* home = std::getenv("HOME");
    return home && *home ? std::string(home) + "/.config/phonemic/receiver.conf" : std::string{};
}
struct ReceiverOptions {
    ReceiverConfig config;
    bool quiet = false, help = false, check = false;
    std::string configPath, savePath;
};
inline ReceiverOptions receiverOptions(const std::vector<std::string>& args, const std::string& defaultPath) {
    ReceiverOptions options;
    options.configPath = defaultPath;
    bool explicitConfig = false, noConfig = false;
    std::vector<std::pair<std::string, std::string>> overrides;
    for (size_t i = 0; i < args.size(); ++i) {
        const auto& arg = args[i];
        if (arg == "--help") { options.help = true; return options; }
        if (arg == "--quiet") { options.quiet = true; continue; }
        if (arg == "--check-config") { options.check = true; continue; }
        if (arg == "--no-config") { noConfig = true; continue; }
        if (arg != "--config" && arg != "--save-config" && arg != "--token" && arg != "--port" && arg != "--jitter-ms" && arg != "--bind")
            throw std::runtime_error("Unknown option: " + arg);
        if (++i == args.size()) throw std::runtime_error("Missing value for " + arg);
        const auto& value = args[i];
        if (arg == "--config") { explicitConfig = true; options.configPath = value; }
        else if (arg == "--save-config") options.savePath = value;
        else overrides.emplace_back(arg == "--token" ? "pairing_code" : arg == "--jitter-ms" ? "jitter_ms" : arg == "--bind" ? "bind_address" : "port", value);
    }
    if (explicitConfig && noConfig) throw std::runtime_error("Use either --config or --no-config");
    if (options.check && !options.savePath.empty()) throw std::runtime_error("Use either --check-config or --save-config");
    if (noConfig) options.configPath.clear();
    if (!options.configPath.empty()) {
        // A dangling symlink or unreadable file is an error, never an instruction
        // to silently fall back to a different pairing code.
        const auto status = std::filesystem::symlink_status(options.configPath);
        const bool exists = std::filesystem::exists(status);
        if (explicitConfig || exists) {
            std::ifstream input(options.configPath);
            if (!input) throw std::runtime_error("Cannot open config: " + options.configPath);
            readConfig(input, options.config);
        } else options.configPath.clear();
    }
    for (const auto& [key, value] : overrides) setConfig(options.config, key, value);
    if (!options.configPath.empty() && !options.config.token)
        throw std::runtime_error("Config must include a nonzero 8-digit pairing_code");
    if (options.check && !options.config.token)
        throw std::runtime_error("No fixed pairing code configured");
    return options;
}
}
