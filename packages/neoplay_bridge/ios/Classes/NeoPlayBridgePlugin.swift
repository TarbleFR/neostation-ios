import Flutter
import Foundation

public final class NeoPlayBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let controller = NPController()
    private let gameHUD = NPGameHUD()
    private let controllerBatteries = NPControllerBatteryStream()
    private var sink: FlutterEventSink?
    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = NeoPlayBridgePlugin()
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "neostation/neoplay", binaryMessenger: registrar.messenger()))
        FlutterEventChannel(name: "neostation/neoplay/events", binaryMessenger: registrar.messenger()).setStreamHandler(plugin)
        FlutterEventChannel(name: "neostation/neoplay/controller_battery", binaryMessenger: registrar.messenger()).setStreamHandler(plugin.controllerBatteries)
        plugin.controller.changed = { [weak plugin] event in plugin?.sink?(event) }
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configureGameHUD":
            guard let args = call.arguments as? [String:Any], let active = args["active"] as? Bool, let labels = args["labels"] as? [String:String], ["battery","controller","percent","unavailable","charging","low"].allSatisfy({ !(labels[$0] ?? "").isEmpty }) else { result(FlutterError(code:"arguments",message:nil,details:nil)); return }
            gameHUD.configure(active:active,labels:labels); result(nil)
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

/// Controller batteries for NeoStation's header: the in-game HUD's readings
/// (same monitor, an unknown state is never a percentage), sent whenever they
/// change while Dart listens; the first event is the current list, empty
/// when no controller is connected.
final class NPControllerBatteryStream: NSObject, FlutterStreamHandler {
    private let monitor = NPControllerBatteryMonitor()
    private var sink: FlutterEventSink?
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        monitor.changed = { [weak self] rows in self?.sink?(rows.map(\.payload)) }
        monitor.start()
        events(monitor.readings.map(\.payload))
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        monitor.changed = nil; monitor.stop(); sink = nil
        return nil
    }
}
