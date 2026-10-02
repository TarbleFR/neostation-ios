import Flutter
import Foundation

public final class NeoPlayBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let controller = NPController()
    private var sink: FlutterEventSink?
    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = NeoPlayBridgePlugin()
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "neostation/neoplay", binaryMessenger: registrar.messenger()))
        FlutterEventChannel(name: "neostation/neoplay/events", binaryMessenger: registrar.messenger()).setStreamHandler(plugin)
        plugin.controller.changed = { [weak plugin] event in plugin?.sink?(event) }
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "snapshot": result(controller.snapshot)
        case "discover": controller.discover(); result(nil)
        case "stopDiscovery": controller.stopDiscovery(); result(nil)
        case "disconnect": controller.stop(); result(nil)
        case "connect":
            guard let args = call.arguments as? [String: Any], let id = args["id"] as? String, let label = args["stopLabel"] as? String else { result(FlutterError(code: "arguments", message: nil, details: nil)); return }
            do { try controller.connect(id: id, pin: args["pin"] as? String ?? "", stopLabel: label); result(nil) }
            catch { result(FlutterError(code: (error as? NPError)?.rawValue ?? "network", message: nil, details: nil)) }
        default: result(FlutterMethodNotImplemented)
        }
    }
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; events(controller.snapshot); return nil }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
}
