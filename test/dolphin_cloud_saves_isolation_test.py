"""Source invariants supplement the executable Dart save/lock fixture tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(name):
    return (ROOT / name).read_text()


class DolphinCloudSavesIsolationTests(unittest.TestCase):
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

    def test_native_states_and_restore_validators_remain(self):
        source = read('lib/services/dolphin_save_store.dart')
        for name in ('_validStateIdentity', 'DolphinSystemFiles.replaceSnapshot', 'statesForGame', 'Isolate.run'):
            self.assertIn(name, source)
        service = read('lib/services/dolphin_internal_v2_service.dart')
        for name in ("data['token'] != _saveSessionToken", "data['savesFlushed'] != true", 'final previous = _saveAccessFuture;'):
            self.assertIn(name, service)

    def test_cloud_confirmation_and_local_source_separation(self):
        source = read('lib/providers/icloud_save_provider.dart')
        self.assertIn("confirmed?.transferState == 'uploaded'", source)
        self.assertIn('snapshot.contentHash', source)
        self.assertIn('await _restoring?.future', source)
        broker = read('packages/external_folder_access/ios/Classes/ICloudFolderPlugin.swift')
        for name in ('NSFileCoordinator()', 'restoreFolderContents', 'ACCOUNT_CHANGED', 'preserveModificationDates'):
            self.assertIn(name, broker)

if __name__ == '__main__':
    unittest.main()
