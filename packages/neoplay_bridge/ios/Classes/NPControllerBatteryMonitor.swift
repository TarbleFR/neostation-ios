import Foundation
import GameController

struct NPControllerBatteryReading: Equatable {
    let id: ObjectIdentifier
    let player: Int
    let name: String
    let value: NPBatteryValue

    /// The reading for Dart (NeoStation's header): no percentage when the
    /// controller does not report one.
    var payload: [String: Any] {
        ["player": player, "name": name, "percent": value.percent.map { $0 as Any } ?? NSNull(),
         "charge": value.charge.rawValue, "low": value.low]
    }
}

final class NPControllerBatteryMonitor {
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var slots: [ObjectIdentifier: Int] = [:]
    private(set) var readings: [NPControllerBatteryReading] = []
    var changed: (([NPControllerBatteryReading]) -> Void)?
    func start() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.refresh() })
        }
        refresh()
        let timer = Timer(timeInterval:15,repeats:true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 3; RunLoop.main.add(timer,forMode:.common); self.timer = timer
    }
    private func refresh() {
        // isAttachedToDevice is form-factor information, NOT a Bluetooth/USB detector.
        // Include standalone controllers; do not invent their transport or battery values.
        let controllers = GCController.controllers().filter { !$0.isSnapshot && !$0.isAttachedToDevice && $0.extendedGamepad != nil }
        let connected = Set(controllers.map { ObjectIdentifier($0) })
        slots = slots.filter { connected.contains($0.key) }
        for controller in controllers {
            let id = ObjectIdentifier(controller)
            if slots[id] == nil { slots[id] = (1...max(4,controllers.count+1)).first { !slots.values.contains($0) } }
        }
        let next = controllers.map { controller -> NPControllerBatteryReading in
            let id = ObjectIdentifier(controller), battery = controller.battery
            let charge: NPBatteryCharge
            switch battery?.batteryState {
            case .discharging?: charge = .discharging
            case .charging?: charge = .charging
            case .full?: charge = .full
            default: charge = .unknown
            }
            return NPControllerBatteryReading(id:id,player:slots[id] ?? 1,name:controller.vendorName ?? "",value:NPBatteryValue(level:battery?.batteryLevel,charge:charge))
        }.sorted { $0.player < $1.player }
        if next != readings { readings = next; changed?(next) }
    }
    func stop(resetIdentity: Bool = true) {
        precondition(Thread.isMainThread)
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        readings = []; if resetIdentity { slots.removeAll() }; changed?([])
    }
    deinit { timer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
}
