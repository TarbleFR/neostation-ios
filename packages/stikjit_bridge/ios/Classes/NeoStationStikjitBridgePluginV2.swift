import Flutter
import Foundation

/// Third-level composite registration. Keep the validated MeloNX path and
/// independent RPCS3 path unchanged, while routing ARMSX2 through the V2
/// lifecycle bridge that mirrors MeloNX's foreground handoff.
public final class NeoStationStikjitBridgePluginV2: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    StikjitBridgePluginV2.register(with: registrar)
    StikjitArmsx2BridgePluginV2.register(with: registrar)
    StikjitRpcs3BridgePlugin.register(with: registrar)
  }
}
