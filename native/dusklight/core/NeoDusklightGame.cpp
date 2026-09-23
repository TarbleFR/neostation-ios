// Keep game SDK types in C++: Dolphin's BOOL is int, UIKit's BOOL is bool.
// Crossing the boundary with C scalars avoids redefinition and layout hazards.
#include "NeoDusklightHost.h"
#include <dolphin/dolphin.h>
#include "dusk/main.h"
#include "dusk/iso_validate.hpp"
#include "dusk/game_clock.h"
#include "dusk/config.hpp"
#include "dusk/ui/ui.hpp"
#include "dusk/ui/document.hpp"
#include "dusk/ui/input.hpp"
#include "dusk/ui/menu_bar.hpp"
#include "dusk/mouse.h"
#include "dusk/settings.h"
#include "../extern/aurora/lib/time_internal.hpp"
#include <cstdio>
#include <exception>
#include <algorithm>

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
extern "C" void NeoDusklight_SetGameSuspended(int suspended) {
    aurora::time::internal::set_pause_reason(aurora::time::internal::PauseReason::Host, suspended);
    // Release virtual sticks/buttons before hiding the owning SDL window.
    if (auto* touch = dusk::ui::find_document(dusk::ui::DocumentScope::TouchControls))
        touch->hide(false);
    dusk::ui::input::reset_input_state();
    if (suspended) {
        dusk::mouse::on_focus_lost();
        dusk::config::save();
    } else {
        dusk::ui::MenuBar::refresh_tabs();
        dusk::mouse::on_focus_gained();
        dusk::game_clock::reset();
    }
    NeoDusklight_SetAudioSuspended(suspended);
}

extern "C" int NeoDusklight_PreferredFrameRate() {
    if (dusk::getTransientSettings().turboMode) return 0;
    switch (dusk::getSettings().game.enableFrameInterpolation.getValue()) {
    case dusk::FrameInterpMode::Off: return 30;
    case dusk::FrameInterpMode::Capped:
        return std::max(1, dusk::getSettings().video.maxFrameRate.getValue());
    default: return 0;
    }
}

extern "C" void NeoDusklight_OpenMenu() {
    if (auto* menu = dusk::ui::find_document(dusk::ui::DocumentScope::MenuBar)) {
        dusk::ui::bring_document_to_front(*menu);
        menu->show();
    }
}
