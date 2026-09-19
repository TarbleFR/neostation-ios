import Flutter
import Foundation

/// Composite entry point retained for compatibility. ARMSX2 no longer lives
/// in stikjit_bridge: its embedded Core owns an isolated helper/transaction.
/// The validated MeloNX bridge remains unchanged.
public final class NeoStationStikjitBridgePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    StikjitBridgePluginV2.register(with: registrar)
  }
}
