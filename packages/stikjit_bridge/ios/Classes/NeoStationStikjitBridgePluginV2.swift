import Flutter
import Foundation

/// Third-level composite registration: preserve the already validated
/// MeloNX + ARMSX2 plugin registration exactly as-is, then add the independent
/// RPCS3 bridge on its own method channel.
public final class NeoStationStikjitBridgePluginV2: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    NeoStationStikjitBridgePlugin.register(with: registrar)
    StikjitRpcs3BridgePlugin.register(with: registrar)
  }
}
