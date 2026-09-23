#!/usr/bin/env python3
"""Compile the production language-selection functions with controlled disc metadata."""
from pathlib import Path
import re
import subprocess
import tempfile
from rpcs3_atomic_startup_test import extract_function

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'native/dusklight/core/NeoDusklightGame.cpp').read_text()
fixture = r'''
#include <algorithm>
#include <cassert>
#include <span>
#include <vector>
namespace dusk {
enum class GameLanguage { English, German, French, Spanish, Italian, Japanese = 6 };
namespace iso { struct DiscInfo {}; }
struct LanguageSetting {
    GameLanguage value = GameLanguage::English;
    GameLanguage getValue() const { return value; }
    void setValue(GameLanguage v) { value = v; }
};
struct Settings { struct { LanguageSetting language; } game; } settings;
Settings& getSettings() { return settings; }
namespace language {
std::vector<GameLanguage> available;
std::span<const GameLanguage> available_languages(const iso::DiscInfo&) { return available; }
}
}
dusk::iso::DiscInfo gameDiscInfo;
int saved = -1, writes = 0;
int NeoDusklight_LoadGameLanguage() { return saved; }
void NeoDusklight_SaveGameLanguage(int language) { saved = language; ++writes; }
'''
functions = '\n'.join(extract_function(source, signature) for signature in (
    'dusk::GameLanguage SelectedGameLanguage()',
    'void SelectGameLanguage(',
    'extern "C" void NeoDusklight_ApplyGameLanguage()',
))
scenarios = r'''
int main() {
    using namespace dusk;
    language::available = {GameLanguage::English, GameLanguage::German, GameLanguage::French,
                          GameLanguage::Spanish, GameLanguage::Italian};
    assert(SelectedGameLanguage() == GameLanguage::English);
    for (int i = 0; i < 100; ++i) {
        // Choosing French must not replace any live language/resource state.
        settings.game.language.value = GameLanguage::English;
        SelectGameLanguage(GameLanguage::French);
        assert(saved == int(GameLanguage::French));
        assert(SelectedGameLanguage() == GameLanguage::French);
        assert(settings.game.language.value == GameLanguage::English);
        NeoDusklight_ApplyGameLanguage(); // the next cold initialization
        assert(settings.game.language.value == GameLanguage::French);
        SelectGameLanguage(GameLanguage::German);
        assert(settings.game.language.value == GameLanguage::French);
    }
    // A malformed or unavailable preference never selects nonexistent assets.
    const auto before = writes;
    SelectGameLanguage(GameLanguage::Japanese);
    assert(writes == before);
    saved = 99;
    assert(SelectedGameLanguage() == GameLanguage::French);
    saved = int(GameLanguage::French);
    language::available = {GameLanguage::English};
    NeoDusklight_ApplyGameLanguage();
    assert(settings.game.language.value == GameLanguage::English);
    assert(saved == int(GameLanguage::French)); // preserve choice for compatible discs
    language::available = {GameLanguage::Japanese};
    NeoDusklight_ApplyGameLanguage();
    assert(settings.game.language.value == GameLanguage::Japanese);
}
'''
with tempfile.TemporaryDirectory(prefix='dusklight-language-') as tmp:
    cpp = Path(tmp) / 'language.cpp'
    binary = Path(tmp) / 'language'
    cpp.write_text(fixture + functions + scenarios)
    subprocess.run(['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

main = (ROOT / 'native/dusklight/upstream/src/m_Do/m_Do_main.cpp').read_text()
assert main.count('NeoDusklight_ApplyGameLanguage();') == 1
assert main.index('dvd_opened = aurora_dvd_open(') < main.index('NeoDusklight_ApplyGameLanguage();') < main.index('    LanguageInit();')
assert 'gameDiscInfo = disc;' in source
assert 'available_languages(gameDiscInfo)' in source
assert '.on_pressed([language] { SelectGameLanguage(language); })' in source
menu = (ROOT / 'native/dusklight/upstream/src/dusk/ui/menu_bar.cpp').read_text()
assert 'NeoDusklight_OpenLanguageMenu();' in menu
native = (ROOT / 'native/dusklight/core/NeoDusklightCore.mm').read_text()
assert native.count('@"NeoDusklightGameLanguage"') == 2
assert 'NeoDusklight_ApplyGameLanguage' not in native, 'Warm resume must not change game resources'
catalog = (ROOT / 'lib/l10n/dusklight_locale.dart').read_text()
for key in ('gameLanguage', 'gameLanguageHelp', 'languageEnglish', 'languageGerman',
            'languageFrench', 'languageSpanish', 'languageItalian', 'languageJapanese'):
    assert len(re.findall(r'''["']''' + key + r'''["']\s*:''', catalog)) == 12, key
print('PASS: disc-limited language choice, 100 deferred changes, cold application, twelve UI locales')
