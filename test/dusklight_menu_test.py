#!/usr/bin/env python3
"""Run production menu/visibility functions with a minimal RmlUI document fixture.

The fixture models SDK visibility and input sinks, not the menu policy under test.
UIKit hit-testing and real RmlUI animation still require the device checklist.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'native/dusklight'
adapter = (NATIVE / 'core/NeoDusklightGame.cpp').read_text()
ui = (NATIVE / 'upstream/src/dusk/ui/ui.cpp').read_text()


def function(source, signature):
    start = source.index(signature)
    end = source.index('\n}', start) + 2
    return source[start:end] + '\n'


fixture = r'''
#include <algorithm>
#include <cassert>
#include <memory>
#include <vector>
static bool blocked = false, prelaunch = false;
static int saves = 0, resets = 0, reordered = 0;
namespace dusk {
struct Settings { struct { bool wasPresetChosen = true; } backend; } settings;
Settings& getSettings() { return settings; }
namespace config { void save() { ++saves; } }
namespace ui {
enum class DocumentScope { MenuBar, Window };
class Document {
public:
    bool rendered = false, open = false, isClosed = false, closing = false;
    bool retained = false;
    explicit Document(bool permanent = false) : retained(permanent) {}
    virtual ~Document() = default;
    virtual bool visible() const { return rendered; }
    virtual void hide(bool close) { rendered = false; isClosed = close; }
    virtual void show() { rendered = open = true; closing = false; }
    bool closed() const { return isClosed; }
    bool pending_close() const { return closing; }
    bool permanent() const { return retained; }
    void force_hide(bool close) { hide(close); Document::hide(close); }
};
class AnimatedDocument : public Document {
public:
    using Document::Document;
    bool visible() const override { return open; }
    void hide(bool close) override { open = false; closing = close; }
};
std::vector<std::unique_ptr<Document>> sDocumentStack;
// Passive touch controls must never be included in menu visibility/closure.
std::vector<std::unique_ptr<Document>> sPassiveDocuments;
AnimatedDocument* menu = nullptr;
Document* find_document(DocumentScope) { return menu; }
void bring_document_to_front(Document& doc) {
    ++reordered;
    auto it = std::find_if(sDocumentStack.begin(), sDocumentStack.end(),
                         [&](auto& item) { return item.get() == &doc; });
    auto value = std::move(*it);
    sDocumentStack.erase(it);
    sDocumentStack.push_back(std::move(value));
}
bool is_prelaunch_open() { return prelaunch; }
bool any_document_visible() noexcept;
namespace input {
void sync_input_block() { blocked = any_document_visible(); }
void reset_input_state() { ++resets; }
}
'''
production = ''.join(function(ui, sig) for sig in (
    'void close_all_documents() noexcept',
    'bool any_document_visible() noexcept',
    'bool any_document_rendered() noexcept',
)) + '\n}}\nextern "C" int NeoDusklight_MenuVisible();\n'
production += ''.join(function(adapter, sig) for sig in (
    'extern "C" void NeoDusklight_OpenMenu()',
    'extern "C" int NeoDusklight_MenuVisible()',
    'extern "C" void NeoDusklight_ResumeGameplay()',
))
checks = r'''
int main() {
    using namespace dusk::ui;
    auto root = std::make_unique<AnimatedDocument>(true);
    menu = root.get();
    sDocumentStack.push_back(std::move(root));
    auto touch = std::make_unique<AnimatedDocument>();
    touch->show();
    sPassiveDocuments.push_back(std::move(touch));
    assert(!NeoDusklight_MenuVisible()); // Overlay alone is not a menu.
    for (int cycle = 0; cycle < 100; ++cycle) {
        NeoDusklight_OpenMenu();
        assert(menu->visible() && NeoDusklight_MenuVisible() && blocked);
        const int initialReorders = reordered;
        NeoDusklight_OpenMenu();
        assert(reordered == initialReorders); // Duplicate tap cannot reorder.
        menu->hide(false);
        // During a closing transition the logical menu is hidden, but the
        // UIKit entry must still be absent until RmlUI finishes drawing it.
        assert(!any_document_visible() && NeoDusklight_MenuVisible());
        NeoDusklight_OpenMenu();
        assert(reordered == initialReorders);
        menu->Document::hide(false);
        assert(!NeoDusklight_MenuVisible());
        NeoDusklight_OpenMenu();
        const int beforeNested = reordered;
        // Settings, its nested picker, and a confirmation dialog.
        for (int level = 0; level < 3; ++level) {
            sDocumentStack.back()->force_hide(false);
            auto child = std::make_unique<AnimatedDocument>();
            child->show();
            auto* top = child.get();
            sDocumentStack.push_back(std::move(child));
            NeoDusklight_OpenMenu();
            assert(sDocumentStack.back().get() == top && reordered == beforeNested);
            assert(NeoDusklight_MenuVisible());
        }
        auto* fading = sDocumentStack.back().get();
        fading->hide(true);
        assert(!any_document_visible() && NeoDusklight_MenuVisible());
        NeoDusklight_OpenMenu();
        assert(reordered == beforeNested); // Still cannot cover the fading page.

        // Mandatory setup and prelaunch cannot be bypassed by Resume or X.
        dusk::settings.backend.wasPresetChosen = false;
        const int saved = saves;
        NeoDusklight_ResumeGameplay();
        assert(saves == saved && fading->Document::visible());
        dusk::settings.backend.wasPresetChosen = true;
        prelaunch = true;
        NeoDusklight_ResumeGameplay();
        assert(saves == saved && fading->Document::visible());
        prelaunch = false;
        NeoDusklight_ResumeGameplay();
        assert(!NeoDusklight_MenuVisible() && !blocked);
        assert(saves == saved + 1 && resets == cycle + 1);
        assert(!menu->closed()); // Permanent root is reusable, never destroyed.
        assert(sPassiveDocuments.front()->visible());
        for (auto& doc : sDocumentStack) {
            assert(!doc->Document::visible());
            if (doc.get() != menu) assert(doc->closed());
        }
        std::erase_if(sDocumentStack, [](auto& doc) { return doc->closed(); });
        assert(sDocumentStack.size() == 1);
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    cpp = Path(directory) / 'menu.cpp'
    binary = Path(directory) / 'menu-test'
    cpp.write_text(fixture + production + checks)
    subprocess.run(['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)

core = (NATIVE / 'core/NeoDusklightCore.mm').read_text()
menu = (NATIVE / 'upstream/src/dusk/ui/menu_bar.cpp').read_text()
overlay = (NATIVE / 'upstream/src/dusk/ui/overlay.cpp').read_text()
assert 'backButton' not in core and 'closeGame' not in core
assert core.count('[UIButton buttonWithType:') == 1
assert 'menuButton.hidden = YES; // Consume rapid taps' in core
assert core.index('NeoDusklight_TickGame() != 0') < core.index('menuButton.hidden = NeoDusklight_MenuVisible()')
assert 'menuButton.widthAnchor constraintEqualToConstant:44' in core
assert 'menuButton.heightAnchor constraintEqualToConstant:44' in core
assert 'gameWindow.safeAreaLayoutGuide.trailingAnchor' in core
assert 'gameWindow.safeAreaLayoutGuide.topAnchor' in core
assert menu.count('NeoDusklight_ResumeGameplay();') == 4 # Resume, X, Cancel, confirmed exit.
assert menu.index('NeoDusklight_UIText("resumeGame")') < menu.index('mTabBar->add_tab("Settings"')
assert 'enableFpsOverlay.getValue() && !any_document_rendered()' in overlay
assert 'enableFpsOverlay.setValue' not in overlay

catalog = (ROOT / 'lib/l10n/dusklight_locale.dart').read_text()
native_keys = set(re.findall(r'NeoDusklight_UIText\("(\w+)"\)', menu)) | {'nativeMenu'}
bridge = (ROOT / 'packages/dusklight_internal_bridge/ios/Classes/DusklightInternalBridgePlugin.mm').read_text()
for key in native_keys:
    assert catalog.count(f"'{key}':") == 12, key
    assert f'@"{key}"' in bridge, key
print('PASS: production menu functions, 100 nested cycles, double taps, fading pages, setup guards, input release; UIKit wiring and 12-language labels')
