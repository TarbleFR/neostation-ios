#!/usr/bin/env python3
"""Contract of the embedded libretro route inside NeoStation's iOS launcher."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(relative):
    return (ROOT / relative).read_text(encoding='utf-8')


def require(condition, message):
    if not condition:
        raise SystemExit('libretro route contract: ' + message)


service = read('lib/services/game/game_launch_service.dart')
begin = service.index('// LIBRETRO_INTERNAL_BEGIN: embedded_route')
end = service.index('// LIBRETRO_INTERNAL_END: embedded_route')
block = service[begin:end]
require(service.index("'ios_rpcs3_internal'") < begin, 'RPCS3 keeps its route before libretro')
require(end < service.index("'ios_direct_launch'"), 'libretro runs before the generic iOS handoff')
require(end < service.index('RetroArchLibraryService.launchGameWithDiagnostics'), 'libretro precedes RetroArch')
require(end < service.index('final isArmsx2OwnedRom'), 'PS2 ownership boundary unchanged')
require("'ios_libretro_internal'" in block, 'session registered as ios_libretro_internal')
require('LibretroInternalService.shouldLaunchEmbedded' in block, 'eligibility checked before launching')
require(block.count('return GameLaunchResult.failure(') >= 2, 'failures return instead of falling through')
require('LibretroLocale.launchError(locale, outcome.errorCode)' in block, 'errors are translated')
require('outcome.technicalDetails' in block, 'technical detail kept for diagnostics')
require(service.index('DolphinInternalV2Service.isDolphinSystem') < service.index('if (Platform.isIOS) {'),
        'Dolphin isolation gate still first')

manager = read('lib/services/game_launch_manager.dart')
require("'ios_libretro_internal'," in manager, 'manager treats the session as embedded')
status = read('lib/services/embedded_ios_session_status.dart')
require("'ios_libretro_internal': MethodChannel('neostation/libretro_internal')" in status,
        'session end is polled through isSessionActive')

plugin = read('packages/libretro_internal_bridge/ios/Classes/LibretroInternalBridgePlugin.m')
bridge = read('packages/libretro_internal_bridge/lib/libretro_internal_bridge.dart')
require('@"neostation/libretro_internal"' in plugin and "'neostation/libretro_internal'" in bridge, 'channel names match')
for method in ('isSessionActive', 'availableCores', 'diagnostics', 'stop', 'launch'):
    require(f'@"{method}"' in plugin and f"'{method}'" in bridge, f'method {method} on both sides')
# Skins, screen format, shaders and controls: the Flutter screens read and
# write the frontend settings through the native store (its only writer),
# and inspect, preview and forget skins with the native parser and renderer.
# Each method must exist on both sides of the channel.
for method in ('frontendSettings', 'setFrontendSetting', 'inspectSkin', 'skinPreview', 'forgetSkin'):
    require(f'isEqualToString:@"{method}"' in plugin and f"'{method}'" in bridge, f'method {method} on both sides')
require('invokeMethod:@"sessionEnded"' in plugin and "call.method != 'sessionEnded'" in bridge, 'session end event')
require('retroarch://' not in plugin, 'the embedded engine never opens RetroArch')
# The launch request names the console instead of the retired touch profile:
# its skins and settings directories are checked like the other directories,
# and portrait is installed when the plugin registers.
require('@"profile"' not in plugin, 'the touch profile is retired from the launch request')
for key in ('console', 'consoleName', 'gameKey', 'skinsDirectory', 'frontendDirectory', 'consoleGeometry',
            'lockedOptions', 'logsDirectory'):
    require(f'@"{key}"' in plugin, f'launch key {key} parsed natively')
# The session journal (Documents/Libretro/Logs) is sent with every launch.
libretro_service = read('lib/services/libretro_internal_service.dart')
require("'logsDirectory': (await logsDirectory()).path" in libretro_service, 'session journal directory sent')
require("static Future<Directory> logsDirectory() => _child('Logs');" in libretro_service,
        'session journal under Documents/Libretro/Logs')
require(re.search(r'directoryKeys = @\[[^\]]*@"skinsDirectory", @"frontendDirectory"', plugin) is not None,
        'skins and frontend directories must be absolute paths')
require('LibretroOrientationInstall();' in plugin, 'portrait support installed at plugin registration')

pubspec = read('pubspec.yaml')
require('  - packages/libretro_internal_bridge' in pubspec, 'workspace member')
require('libretro_internal_bridge:\n    path: packages/libretro_internal_bridge' in pubspec, 'path dependency')
package = read('packages/libretro_internal_bridge/pubspec.yaml')
require('pluginClass: LibretroInternalBridgePlugin' in package, 'plugin class declared')
podspec = read('packages/libretro_internal_bridge/ios/libretro_internal_bridge.podspec')
require("s.public_header_files = 'Classes/LibretroInternalBridgePlugin.h'" in podspec, 'only the plugin header is public')
require('RC_CLIENT_SUPPORTS_HASH=1' in podspec, 'rcheevos hashing enabled')

for name in Path(ROOT / 'packages/libretro_internal_bridge/ios/Classes').glob('*.m'):
    source = name.read_text(encoding='utf-8')
    require('preferredLanguages' not in source, f'{name.name} must use the NeoStation language only')
    require('NSLocalizedString' not in source, f'{name.name} must not carry its own translations')

manifest = json.loads(read('build-utils/libretro/cores.json'))
catalog = read('lib/services/libretro_core_catalog.dart')
for core in manifest['cores']:
    require(f"'{core['id']}': LibretroCore(" in catalog, f'{core["id"]} described in the catalog')
    require(core['license'] and core['source'].startswith('https://'), f'{core["id"]} licence and source recorded')

screen = read('lib/screens/game_screen/my_games_list.dart')
require('LIBRETRO_INTERNAL_BEGIN: playlist_actions' in screen, 'floating import button')
require(re.search(r'_isLibretroLibrary\s*\n\s*\? _buildEmbeddedLibretroImportAction\(\)', screen) is not None,
        'tab import action')
require('provider.addRomFolder(romsFolder, scan: false)' in screen, 'imports land in a registered library folder')
print('libretro route contract: OK')
