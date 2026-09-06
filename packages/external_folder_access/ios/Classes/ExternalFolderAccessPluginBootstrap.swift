import Flutter
import UIKit

/// Registers the existing external-folder bridge unchanged, then adds the
/// hardened iCloud Saves broker used by build 208 and later.
public final class ExternalFolderAccessPluginBootstrap: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        ExternalFolderAccessPlugin.register(with: registrar)
        ICloudFolderPluginV2.register(with: registrar)
    }
}
