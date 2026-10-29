#pragma once
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace pm {
// Compare the input actually feeding RemoteIO, not the notification reason or
// output route. Activation and output-only changes can notify without changing it.
struct CaptureRoute {
    std::vector<std::string> inputIDs;
    double sampleRate = 0;
    uint32_t channels = 0;

    bool usable() const {
        return !inputIDs.empty() && std::isfinite(sampleRate) && sampleRate > 0 && channels > 0;
    }
    bool canContinueWith(const CaptureRoute& current) const {
        return usable() && current.usable() && inputIDs == current.inputIDs &&
               sampleRate == current.sampleRate && channels == current.channels;
    }
};
}
