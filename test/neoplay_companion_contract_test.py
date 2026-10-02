from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
class CompanionContracts(unittest.TestCase):
    def test_adapters_match_actual_retained_menu_sources(self):
        sources = {
            'packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm':['DOLDolphinViewController','@selector(menuPressed:)'],
            'packages/armsx2_internal_bridge/ios/Classes/Armsx2InternalBridgePlugin.mm':['Armsx2GameViewController','@selector(menuPressed)'],
            'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm':['RPCS3GameViewController','@selector(menuPressed)'],
            'native/dusklight/core/NeoDusklightCore.mm':['NeoDusklightControls','@selector(openMenu)'],
            'native/kartpad/donor/NeoKartPadDonorCore.mm':['KartPadGameOverlay','FindButtonWithAccessibilityLabel','@"Menu"'],
        }
        for path,markers in sources.items():
            text = (ROOT/path).read_text()
            for marker in markers: self.assertIn(marker,text,path)
    def test_companion_has_no_emulator_or_input_mutation(self):
        names = ['NPGameHUD.swift','NPGameHUDAnchor.swift','NPControllerBatteryMonitor.swift','NPAirPlayMonitor.swift']
        text = '\n'.join((ROOT/'packages/neoplay_bridge/ios/Classes'/n).read_text() for n in names)
        for forbidden in ['method_exchangeImplementations','valueChangedHandler =','pressedChangedHandler =','setCategory(', 'setActive(', 'makeKeyAndVisible(', 'startCapture(', 'isCaptured', 'setValue(', 'value(forKey:']:
            self.assertNotIn(forbidden,text)
        airplay=(ROOT/'packages/neoplay_bridge/ios/Classes/NPAirPlayMonitor.swift').read_text()
        self.assertIn('$0.mirrored != nil',airplay)
        self.assertNotIn('AVRoutePickerView',airplay)

if __name__=='__main__': unittest.main()
