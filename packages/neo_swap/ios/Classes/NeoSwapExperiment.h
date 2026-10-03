// SPDX-License-Identifier: MIT
#pragma once
#include <cstring>

// Immutable, process-wide research profile. Switching backing during a game
// would break guest aliases; comparison builds must restart the application.
namespace neostation::experiment {
enum class Mode { baseline, relay, integrated };
struct Profile {
    Mode mode = Mode::integrated;
    bool valid = true;
    bool configured = false;
    bool relay() const noexcept { return mode != Mode::baseline; }
    bool donors() const noexcept { return mode == Mode::integrated; }
    bool storage() const noexcept { return mode == Mode::integrated; }
    const char* name() const noexcept {
        return mode == Mode::baseline ? "baseline" : mode == Mode::relay ? "relay" : "integrated";
    }
};
inline Profile parse(const char* name) noexcept {
    if (!name) return {};
    if (!std::strcmp(name, "integrated")) return {Mode::integrated, true, true};
    if (!std::strcmp(name, "baseline")) return {Mode::baseline, true, true};
    if (!std::strcmp(name, "relay")) return {Mode::relay, true, true};
    return {Mode::baseline, false, true}; // a bad experiment label must not enable allocations
}
}
#ifdef __OBJC__
#import <Foundation/Foundation.h>
inline const neostation::experiment::Profile& NeoSwapExperimentProfile() {
    static const auto profile = [] {
        id value = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NeoSwapResearchMode"];
        if (!value) return neostation::experiment::parse(nullptr);
        if (![value isKindOfClass:NSString.class])
            return neostation::experiment::Profile{neostation::experiment::Mode::baseline, false, true};
        return neostation::experiment::parse([value UTF8String]);
    }();
    return profile;
}
#endif
