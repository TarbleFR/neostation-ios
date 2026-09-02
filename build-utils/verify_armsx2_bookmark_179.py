from pathlib import Path


def require(path: str, needle: str) -> None:
    text = Path(path).read_text(encoding='utf-8')
    if needle not in text:
        raise SystemExit(f'MISSING in {path}: {needle}')


def forbid(path: str, needle: str) -> None:
    text = Path(path).read_text(encoding='utf-8')
    if needle in text:
        raise SystemExit(f'FORBIDDEN in {path}: {needle}')


# ManicEMU runtime integration must be gone.
for dead in (
    'lib/services/manic_emu_launch_service.dart',
    'lib/services/ios_emulator_preference_service.dart',
    'lib/l10n/manic_emu_locale.dart',
):
    if Path(dead).exists():
        raise SystemExit(f'FORBIDDEN runtime file still exists: {dead}')

manic_terms = (
    'Manic EMU', 'ManicEMU', 'manicemu', 'manic_emu',
    'IosEmulatorPreferenceService', 'IosLibraryEmulator',
    'linkedManicEmuFolderPath',
)
for root in (Path('lib'), Path('packages')):
    for file in root.rglob('*'):
        if not file.is_file():
            continue
        try:
            text = file.read_text(encoding='utf-8')
        except (UnicodeDecodeError, OSError):
            continue
        for term in manic_terms:
            if term in text:
                raise SystemExit(f'FORBIDDEN ManicEMU term {term!r} in {file}')

# One ARMSX2 root/bookmark for both library and NeoSync save-folder reading.
require('lib/services/armsx2_folder_service.dart', "static const String bookmarkKey = 'armsx2'")
require('lib/services/config_service.dart', 'linkedArmsx2FolderPath')
require('lib/services/config_service.dart', 'linkedArmsx2GameFolderPath')
forbid('lib/services/config_service.dart', 'linkedArmsx2SaveFolderPath')
forbid('lib/services/config_service.dart', 'armsx2NeoSyncBookmarkKey')
require(
    'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart',
    'onLinkPressed: _linkArmsx2RootFolder',
)
forbid(
    'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart',
    'Armsx2LibraryService.requestLibrarySync()',
)

# ARMSX2 must not consult RetroArch ownership/root data.
forbid('lib/services/armsx2_folder_service.dart', 'linkedExternalFolderPath')
require(
    'lib/services/game/game_launch_service.dart',
    'final isArmsx2OwnedRom = Armsx2FolderService.ownsRomPath',
)
require(
    'lib/services/game/game_launch_service.dart',
    'if (isArmsx2OwnedRom || isArmsx2VirtualRom)',
)
require(
    'lib/providers/neosync/neosync_path_resolver.dart',
    'PS2 on iOS must never merge RetroArch and ARMSX2 save roots',
)
require(
    'lib/providers/neosync/neosync_path_resolver.dart',
    'return await Armsx2FolderService.resolveSaveDirectories',
)

# Physical filenames from the linked ARMSX2 library must be URI-component
# encoded. This fixes spaces being changed to literal '+' characters.
require('lib/services/armsx2_library_service.dart', 'Uri.encodeComponent(fileName)')
require(
    'lib/services/armsx2_library_service.dart',
    "Uri.parse('armsx2://launch?game=$encodedFileName')",
)
forbid(
    'lib/services/armsx2_library_service.dart',
    "queryParameters: {'game': fileName}",
)

print('Build 179 architecture verification passed')
