// Keep game SDK types in C++: Dolphin's BOOL is int, UIKit's BOOL is bool.
// Crossing the boundary with C scalars avoids redefinition and layout hazards.
#include "NeoDusklightHost.h"
#include <dolphin/dolphin.h>
#include "dusk/main.h"
#include "dusk/iso_validate.hpp"
#include <cstdio>
#include <exception>

int game_main(int argc, char* argv[]);

extern "C" int NeoDusklight_InspectDisc(const char* path, char* error, size_t size) {
    dusk::iso::DiscInfo disc{};
    try {
        const auto validation = dusk::iso::inspect(path, disc);
        if (validation == dusk::iso::ValidationError::Success) return 1;
        if (error && size) {
            snprintf(error, size, "Dusklight rejected the disc (validation %d, ID %s, revision %u).",
                     static_cast<int>(validation), disc.gameId.c_str(), unsigned(disc.revision));
        }
    } catch (const std::exception& ex) {
        if (error && size) snprintf(error, size, "%s", ex.what());
    }
    return 0;
}

extern "C" int NeoDusklight_RunGame(int argc, char** argv) { return game_main(argc, argv); }
extern "C" void NeoDusklight_StopGame() { dusk::IsRunning = false; }
