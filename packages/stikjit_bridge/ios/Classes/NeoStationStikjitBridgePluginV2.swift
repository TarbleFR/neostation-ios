import Flutter
import Foundation

/// Composite registration keeps the validated MeloNX / legacy-ARMSX2 / RPCS3
/// channels untouched and adds the race-free ARMSX2 safe-boot channel beside
/// them. Dart explicitly opts into the safe channel, so rollback remains local.
public final class NeoStationStikjitBridgePluginV2: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    NeoStationStikjitBridgePlugin.register(with: registrar)
    StikjitArmsx2SafeBridgePlugin.register(with: registrar)
    StikjitRpcs3BridgePlugin.register(with: registrar)
  }
}
