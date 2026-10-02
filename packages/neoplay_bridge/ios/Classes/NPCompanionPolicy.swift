import Foundation

enum NPBatteryCharge: String { case unknown, discharging, charging, full }
struct NPBatteryValue: Equatable {
    let percent: Int?
    let charge: NPBatteryCharge
    init(level: Float?, charge: NPBatteryCharge) {
        self.charge = charge
        // GCDeviceBattery defaults to 0.0. Unknown state must never become a false 0%.
        if charge != .unknown, let level, level.isFinite, (0...1).contains(level), !(charge == .full && level == 0) {
            percent = Int((Double(level) * 100).rounded())
        } else { percent = nil }
    }
    var low: Bool { charge == .discharging && percent.map { $0 <= 15 } == true }
}

struct NPAirPlayFacts: Equatable {
    let externalMirroring: Bool
    let airPlayAudio: Bool
    var status: String { externalMirroring ? "mirrorDetected" : (airPlayAudio ? "audioOnly" : "notDetected") }
    // A route or a captured screen alone is not proof of an Apple TV video connection.
    var exactReceiverIdentified: Bool { false }
}

enum NPCompanionPlacement {
    static func frame(anchor: CGRect, safe: CGRect, size: CGSize, obstacles: [CGRect]) -> CGRect? {
        guard [safe.minX,safe.minY,safe.width,safe.height,anchor.minX,anchor.minY,anchor.width,anchor.height,size.width,size.height].allSatisfy({ $0.isFinite }), size.width > 0, size.height > 0, size.width <= safe.width, size.height <= safe.height else { return nil }
        let gap: CGFloat = 8
        let rowY = min(max(safe.minY, anchor.midY - size.height / 2), safe.maxY - size.height)
        var candidates = [CGRect(x:anchor.maxX+gap,y:rowY,width:size.width,height:size.height), CGRect(x:anchor.minX-gap-size.width,y:rowY,width:size.width,height:size.height)]
        for block in obstacles.sorted(by: { $0.minX < $1.minX }) where block.maxY > rowY && block.minY < rowY + size.height {
            candidates.append(CGRect(x:block.maxX+gap,y:rowY,width:size.width,height:size.height))
        }
        let belowX = min(max(anchor.minX,safe.minX), safe.maxX-size.width)
        candidates.append(CGRect(x:belowX,y:anchor.maxY+gap,width:size.width,height:size.height))
        for rect in candidates where safe.contains(rect) && !rect.intersects(anchor) && !obstacles.contains(where: { $0.intersects(rect) }) { return rect }
        return nil // No safe space: omit the HUD instead of covering touch controls.
    }
}
