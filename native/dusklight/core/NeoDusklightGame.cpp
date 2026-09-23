// Keep game SDK types in C++: Dolphin's BOOL is int, UIKit's BOOL is bool.
// Crossing the boundary with C scalars avoids redefinition and layout hazards.
#include "NeoDusklightHost.h"
#include <dolphin/dolphin.h>
#include "dusk/main.h"
#include "dusk/iso_validate.hpp"
#include "dusk/language.hpp"
#include "dusk/game_clock.h"
#include "dusk/config.hpp"
#include "dusk/ui/ui.hpp"
#include "dusk/ui/document.hpp"
#include "dusk/ui/input.hpp"
#include "dusk/ui/menu_bar.hpp"
#include "dusk/ui/pane.hpp"
#include "dusk/ui/window.hpp"
#include "dusk/mouse.h"
#include "dusk/settings.h"
#include "../extern/aurora/lib/time_internal.hpp"
#include "../extern/aurora/lib/gfx/frame.hpp"
#include <cstdio>
#include <exception>
#include <algorithm>

int game_main(int argc, char* argv[]);

namespace {
dusk::iso::DiscInfo gameDiscInfo{};

dusk::GameLanguage SelectedGameLanguage() {
    const auto languages = dusk::language::available_languages(gameDiscInfo);
    const int saved = NeoDusklight_LoadGameLanguage();
    for (const auto language : languages)
        if (static_cast<int>(language) == saved) return language;
    const auto current = dusk::getSettings().game.language.getValue();
    if (std::find(languages.begin(), languages.end(), current) != languages.end()) return current;
    return languages.front();
}

const char* GameLanguageLabel(dusk::GameLanguage language) {
    switch (language) {
    case dusk::GameLanguage::German: return NeoDusklight_UIText("languageGerman");
    case dusk::GameLanguage::French: return NeoDusklight_UIText("languageFrench");
    case dusk::GameLanguage::Spanish: return NeoDusklight_UIText("languageSpanish");
    case dusk::GameLanguage::Italian: return NeoDusklight_UIText("languageItalian");
    case dusk::GameLanguage::Japanese: return NeoDusklight_UIText("languageJapanese");
    default: return NeoDusklight_UIText("languageEnglish");
    }
}

void SelectGameLanguage(dusk::GameLanguage language) {
    const auto languages = dusk::language::available_languages(gameDiscInfo);
    if (std::find(languages.begin(), languages.end(), language) == languages.end()) return;
    // Keep the pending choice separate from live configuration: msg_folder()
    // reads that configuration while a session is running. Switching it here
    // would mix freshly loaded messages with the language cached at startup.
    NeoDusklight_SaveGameLanguage(static_cast<int>(language));
}

class LanguageWindow : public dusk::ui::Window {
public:
    LanguageWindow() {
        add_tab(NeoDusklight_UIText("gameLanguage"), [this](Rml::Element* content) {
            using namespace dusk::ui;
            auto& choices = add_child<Pane>(content, Pane::Type::Controlled);
            auto& help = add_child<Pane>(content, Pane::Type::Uncontrolled);
            help.add_text(NeoDusklight_UIText("gameLanguageHelp"));
            for (const auto language : dusk::language::available_languages(gameDiscInfo)) {
                choices.add_button({
                    .text = GameLanguageLabel(language),
                    .isSelected = [language] { return SelectedGameLanguage() == language; },
                }).on_pressed([language] { SelectGameLanguage(language); });
            }
        });
    }
};
}

extern "C" void NeoDusklight_OpenLanguageMenu() {
    dusk::ui::push_document(std::make_unique<LanguageWindow>());
}

extern "C" void NeoDusklight_ApplyGameLanguage() {
    // Called only during cold initialization, after disc validation and before
    // LanguageInit/resource loading. Warm resumes must retain their language.
    dusk::getSettings().game.language.setValue(SelectedGameLanguage());
}

extern "C" int NeoDusklight_InspectDisc(const char* path, char* error, size_t size) {
    dusk::iso::DiscInfo disc{};
    try {
        const auto validation = dusk::iso::inspect(path, disc);
        if (validation == dusk::iso::ValidationError::Success) {
            gameDiscInfo = disc;
            return 1;
        }
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
extern "C" int NeoDusklight_ReleaseFrameResources() {
    return aurora::gfx::release_frame_resources() ? 1 : 0;
}
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
    // A delayed/double tap must never lift MenuBar over Settings or a modal.
    if (NeoDusklight_MenuVisible()) return;
    if (auto* menu = dusk::ui::find_document(dusk::ui::DocumentScope::MenuBar)) {
        dusk::ui::bring_document_to_front(*menu);
        menu->show();
        dusk::ui::input::sync_input_block();
    }
}

extern "C" int NeoDusklight_MenuVisible() {
    return dusk::ui::any_document_rendered() ? 1 : 0;
}

extern "C" void NeoDusklight_ResumeGameplay() {
    // Initial setup and the prelaunch chooser must complete normally.
    if (!dusk::getSettings().backend.wasPresetChosen || dusk::ui::is_prelaunch_open()) return;
    // Close the complete stack, not just MenuBar: a covered Settings/Mods page
    // must not keep intercepting input or reappear on the next menu opening.
    dusk::ui::close_all_documents();
    dusk::ui::input::reset_input_state();
    dusk::config::save();
}
