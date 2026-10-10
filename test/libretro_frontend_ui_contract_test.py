#!/usr/bin/env python3
"""Source contract of the embedded-console Flutter pages (consoles, skins,
Provenance catalog) and of their two entry points.

- No hard-coded user-visible text in lib/screens/libretro/*.dart or in the
  playlist actions: every label comes from LibretroLocale (twelve languages),
  product names and skin data come from variables.
- Every LibretroLocale key those files name exists in the English catalog
  (test/libretro_locale_test.dart checks that the twelve maps share their keys).
- Settings › Folders: outside the `embedded_consoles` markers the file is
  byte-for-byte the reviewed a5650b9b version. The Embedded consoles item is
  added before the ES-DE early return (which always returns on iOS) and only
  on iOS.
- The playlist actions keep their contract (integrated_import_tab_contract)
  and gain the Skins item.
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREENS = sorted((ROOT / 'lib/screens/libretro').glob('*.dart'))
PLAYLIST = 'lib/widgets/libretro_internal_playlist_actions.dart'
DIRECTORIES = 'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart'
REVIEWED = 'a5650b9b'
BEGIN = '// LIBRETRO_INTERNAL_BEGIN: embedded_consoles'
END = '// LIBRETRO_INTERNAL_END: embedded_consoles'

# Lines allowed in the directories page outside the markers, beyond the
# reviewed version. Empty: the item, its action, icon, trailing button and its
# LibretroLocale texts all sit inside marked blocks (the two Text() blocks
# prefix the original expression with a conditional, so removing a block
# restores the original expression exactly).
ALLOWED_EXTRA_LINES = []


def read(relative):
    return (ROOT / relative).read_text(encoding='utf-8')


def require(condition, message):
    if not condition:
        raise SystemExit('libretro frontend UI contract: ' + message)


def strip_comments(source):
    """Removes // comments (doc comments included) so prose never counts as UI."""
    return re.sub(r'(?m)^\s*//.*$', '', source)


def english_keys():
    source = read('lib/l10n/libretro_locale.dart')
    start = source.index("    'en': {")
    end = source.index('\n    },', start)
    return set(re.findall(r"^\s*'([A-Za-z0-9_]+)':", source[start:end], re.M))


EN = english_keys()
require(len(EN) > 200, 'English LibretroLocale map not found')

# 1. Pages exist and are wired.
names = {path.name for path in SCREENS}
for expected in ('libretro_consoles_screen.dart', 'libretro_skin_manager_screen.dart',
                 'libretro_skin_catalog_screen.dart'):
    require(expected in names, expected + ' missing')

LITERAL_TEXT = re.compile(r"""\bText\(\s*r?['"]""")
LITERAL_NAMED = re.compile(
    r"""\b(tooltip|semanticsLabel|semanticLabel|labelText|hintText|helperText|errorText|"""
    r"""prefixText|suffixText|counterText|title|message|label)\s*:\s*r?['"]""")
KEY_CALL = re.compile(
    r"""(?:\b_t|\b_f|LibretroLocale\.text|LibretroLocale\.formatContext)\(\s*(?:context\s*,\s*)?'([A-Za-z0-9_]+)'""")

ui_files = [path.relative_to(ROOT).as_posix() for path in SCREENS] + [PLAYLIST]
for relative in ui_files:
    code = strip_comments(read(relative))
    require(not LITERAL_TEXT.search(code), f'{relative}: Text() with a literal string')
    hit = LITERAL_NAMED.search(code)
    require(hit is None, f'{relative}: literal string for {hit.group(1) if hit else ""}:')
    require('AppLocale.' not in code, f'{relative}: texts come from LibretroLocale')
    for key in KEY_CALL.findall(code):
        require(key in EN, f'{relative}: LibretroLocale key {key!r} is not in the English catalog')

manager = read('lib/screens/libretro/libretro_skin_manager_screen.dart')
catalog = read('lib/screens/libretro/libretro_skin_catalog_screen.dart')
consoles = read('lib/screens/libretro/libretro_consoles_screen.dart')

# Every page takes the controller from the screen underneath and gives it back.
require('GamepadNavigationManager.pushLayer(' in manager and 'GamepadNavigationManager.popLayer(' in manager,
        'pages register a gamepad navigation layer')
for name, source in (('manager', manager), ('catalog', catalog), ('consoles', consoles)):
    require(re.search(r'with\s+LibretroPageNavigation<', source), f'{name} page uses LibretroPageNavigation')
require('ActivateIntent' in manager and 'focusInDirection' in manager, 'D-pad moves the focus, A activates it')

# Skins: translated import remarks and refusals, confirmed deletion and
# replacement, licence notice, previews from the native renderer.
require('LibretroLocale.skinErrorKeys' in manager and 'LibretroLocale.skinMessage(' in manager,
        'native skin codes are translated through LibretroLocale')
for key in ('skinsDeleteConfirm', 'skinsReplaceConfirm', 'skinsImportRemarks', 'skinsLicenseNotice',
            'skinsSelectedPortrait', 'skinsSelectedLandscape', 'skinsAuthorUnknown', 'skinsCredits',
            'skinsLicense', 'skinsForConsoles', 'skinsResetDefault', 'skinsUseBoth'):
    require(f"'{key}'" in manager, f'manager shows {key}')
require(manager.count('ConfirmActionDialog.show(') >= 2, 'delete and replace are confirmed')
require('skins.discard(' in manager, 'a declined replacement is discarded')
require('.preview(' in manager and 'FutureBuilder<Uint8List?>' in manager, 'previews come from the native renderer')
require('pickAndImport()' in manager, 'Files import goes through LibretroSkinService')

# Catalog: same import pipeline, every state translated.
require('showLibretroSkinImportResult(' in catalog, 'catalog installs show the manager messages')
for key in ('catalogLoading', 'catalogFailed', 'catalogRetry', 'catalogEmpty', 'catalogSearch',
            'catalogInstall', 'catalogInstalling', 'catalogDownloads', 'catalogNotDirect'):
    require(f"'{key}'" in catalog, f'catalog shows {key}')
require('isDirectDownload' in catalog and 'errorBuilder' in catalog, 'non-archive links and broken thumbnails')

# Consoles: every console, import into one of the user's own library folders
# (10 October 2026: never a second library next to theirs; NeoStation's roms
# folder only when none is registered), rescan of the receiving system only,
# and NeoStation's library actions (console folders, moving a library in).
require('LibretroCoreCatalog.consoles.values' in consoles, 'every embedded console is listed')
require('LibretroInternalService.importGamesForConsole(' in consoles, 'import for a console without games')
require('chooseLibretroImportDestination(' in consoles and 'library: destination.library' in consoles,
        "imports land in one of the user's library folders")
require('addRomFolder(createdLibraryRoot, scan: false)' in consoles,
        "NeoStation's roms folder is registered only when it received the games")
require("'importLibraryUnavailable'" in consoles and "'importAlreadyPresent'" in consoles,
        'an unreachable library and games already there are announced')
require('createNeoStationConsoleFolders(' in consoles and 'moveLibraryIntoNeoStation(' in consoles,
        'console folders and library move')
require('rescanSystemSilent(' in consoles and 'result.systemFolder' in consoles, 'the receiving system is rescanned')
require("'gamesImported'" in consoles and "'gamesRejected'" in consoles and "'importFailed'" in consoles,
        'import notifications')

# 2. Settings › Folders.
directories = read(DIRECTORIES)
require(directories.count(BEGIN) == directories.count(END) and directories.count(BEGIN) >= 5,
        'balanced embedded_consoles markers')
blocks = []
kept = []
inside = False
for line in directories.splitlines(keepends=True):
    stripped = line.strip()
    if stripped == BEGIN:
        require(not inside, 'nested embedded_consoles marker')
        inside = True
        blocks.append('')
        continue
    if stripped == END:
        require(inside, 'embedded_consoles end without begin')
        inside = False
        continue
    if inside:
        blocks[-1] += line
    else:
        kept.append(line)
require(not inside, 'unterminated embedded_consoles block')

try:
    reviewed = subprocess.run(['git', 'show', f'{REVIEWED}:{DIRECTORIES}'], cwd=ROOT, check=True,
                              capture_output=True).stdout.decode('utf-8')
except (OSError, subprocess.CalledProcessError) as error:
    raise SystemExit(f'libretro frontend UI contract: cannot read {REVIEWED}:{DIRECTORIES} ({error})')

current_lines = [line for line in kept if line.rstrip('\r\n') not in ALLOWED_EXTRA_LINES]
require(''.join(current_lines) == reviewed,
        'directories_settings_content.dart differs from a5650b9b outside the embedded_consoles markers')

marked = ''.join(blocks)
require("'action': 'libretro_consoles'" in marked and 'if (Platform.isIOS)' in marked, 'iOS-only item')
require("'embeddedConsoles'" in marked and "'embeddedConsolesSubtitle'" in marked
        and 'LibretroLocale.text(' in marked, 'item texts from LibretroLocale')
require('Symbols.sports_esports_rounded' in marked, 'item icon')
require('LibretroConsolesScreen()' in marked, 'item opens the consoles page')
build_items = directories[directories.index('void _buildDirectoryItems()'):]
require(build_items.index("'action': 'libretro_consoles'") < build_items.index('if (!_esdeSupported) {'),
        'item added before the ES-DE early return (always taken on iOS)')

# 3. Playlist actions.
playlist = read(PLAYLIST)
require('if (widget.embedded) return button' in playlist, 'embedded tab action unchanged')
require("const ValueKey('libretro-internal-import-menu')" in playlist, 'menu key unchanged')
for item in ("value: 'games'", "value: 'retroarch'", "value: 'skins'"):
    require(item in playlist, f'menu item {item}')
for key in ("_t('importMenu')", "_t('importGames')", "_t('importRetroArch')", "_t('skins')"):
    require(key in playlist, f'menu label {key}')
require('LibretroCoreCatalog.bindingFor(widget.systemFolder)?.console' in playlist,
        'skins of the playlist console')
require('LibretroSkinManagerScreen(console: console)' in playlist, 'Skins opens the skin manager')

print('libretro frontend UI contract: OK')
