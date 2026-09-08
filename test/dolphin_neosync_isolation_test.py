"""Source invariants supplement the executable Dart save/lock fixture tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(name):
    return (ROOT / name).read_text()


class DolphinNeoSyncIsolationTests(unittest.TestCase):
    def test_native_identity_does_not_initialize_core_or_jit(self):
        source = read('build-utils/patch_dolphin_internal_core_v2.py')
        identity = source.split('char* neostation_dolphin_save_identity(', 1)[1].split('int32_t neostation_dolphin_initialize(', 1)[0]
        for needed in ('DiscIO::CreateVolume', 'GetGameID()', 'GetTitleID()', 'GetRegion()', 'ExpectedPlatform'):
            self.assertIn(needed, identity)
        for forbidden in ('UICommon::Init', 'Core::Init', 'RunExecutableProbe', 'StikJIT'):
            self.assertNotIn(forbidden, identity)

    def test_stop_event_follows_native_shutdown_and_ui_cleanup(self):
        source = read('packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm')
        stop = source.split('- (void)stopRuntimeWithReason:', 1)[1].split('- (void)prepareSessionForStop', 1)[0]
        self.assertLess(stop.index('neostation_dolphin_stop('), stop.index('cleanupSharedResourcesAndUI'))
        self.assertLess(stop.index('cleanupSharedResourcesAndUI'), stop.index('invokeMethod:@"saveSessionStopped"'))
        self.assertIn('saveToken.length > 0 && savesFlushed', stop)
        self.assertIn('self.launchInProgress || self.stopInProgress', source)

    def test_save_exclusion_and_stop_token_are_local_to_dolphin(self):
        source = read('lib/services/dolphin_internal_v2_service.dart')
        self.assertIn('return await _withSystemImport(() async {', source)
        self.assertIn("data['token'] != _saveSessionToken", source)
        self.assertIn("data['savesFlushed'] != true", source)
        self.assertIn('final previous = _saveAccessFuture;', source)
        launcher = read('lib/services/game/game_launch_service.dart')
        scoped = launcher.split('DOLPHIN_ISOLATION_BEGIN: explicit_gc_wii_route', 1)[1].split('DOLPHIN_ISOLATION_END: explicit_gc_wii_route', 1)[0]
        self.assertIn("sync?.providerId == 'neosync'", scoped)
        self.assertIn('onSessionStopped:', scoped)
        self.assertIn('game.cloudSyncEnabled == true', scoped)

    def test_no_partial_page_is_treated_as_complete_dolphin_cloud_listing(self):
        source = read('lib/services/neosync/neo_sync_service_base.dart')
        scoped = source.split('DOLPHIN_ISOLATION_BEGIN: dolphin_complete_cloud_listing', 1)[1].split('DOLPHIN_ISOLATION_END: dolphin_complete_cloud_listing', 1)[0]
        self.assertIn("'offset': '$offset'", scoped)
        self.assertIn('!seen.add(file.id)', scoped)
        self.assertIn('refusing an incomplete list', scoped)
        self.assertIn('Future<Map<String, dynamic>> getFiles() async', source)

    def test_success_requires_cloud_or_restored_content_confirmation(self):
        source = read('lib/providers/neosync/neosync_dolphin.dart')
        self.assertIn('confirmed.length != 1', source)
        self.assertIn('restored?.checksum != remoteHash', source)
        self.assertIn('current?.checksum != local?.checksum', source)
        self.assertIn('DolphinSyncDecision.conflict', source)
        self.assertIn('game.cloudSyncEnabled != true', source)
        self.assertIn('!system.neosync.sync', source)
        self.assertNotIn('contentHashOnly: true', source)

    def test_v1_uses_only_raw_cards_and_wii_title_data_while_other_emulators_stay_isolated(self):
        source = read('lib/services/dolphin_neosync_store.dart')
        self.assertIn("emulator = 'dolphinios'", source)
        self.assertNotIn('linkedRetroArchFolderPath', source)

        for_game = source.split(
            'static List<DolphinSaveTarget> forGame(DolphinSaveIdentity game)', 1
        )[1].split('static List<DolphinSaveTarget> statesForGame', 1)[0]
        self.assertIn('MemoryCard', for_game)
        self.assertIn("'wii-data'", for_game)
        self.assertNotIn("'gci'", for_game)

        state_targets = source.split(
            'static List<DolphinSaveTarget> statesForGame', 1
        )[1].split('static DolphinSaveTarget? raw', 1)[0]
        self.assertNotIn('DolphinSaveTarget._', state_targets)

        parser = source.split(
            'static DolphinSaveTarget? parse(String cloudPath)', 1
        )[1].split('/// Reserved namespace', 1)[0]
        self.assertIn('parsed.isState', parser)
        self.assertNotIn('gci-', parser)

        active_targets = source.split(
            'Future<List<DolphinSaveTarget>> targetsForGame', 1
        )[1].split('Future<DolphinSaveSnapshot?> snapshot', 1)[0]
        self.assertNotIn('statesForGame', active_targets)
        self.assertIn('DolphinSystemFiles.replaceSnapshot', source)
        self.assertIn('Isolate.run', source)
        download = read('lib/providers/neosync/neosync_download.dart')
        self.assertGreaterEqual(download.count('DolphinSaveTarget.ownsCloudPath'), 3)


if __name__ == '__main__':
    unittest.main()
