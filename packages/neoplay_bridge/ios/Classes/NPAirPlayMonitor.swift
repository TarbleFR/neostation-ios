import UIKit
import AVFAudio

// Public system observations only. Never open private settings URLs, synthesize
// Control Center taps, or substitute an audio route picker for screen mirroring.
final class NPAirPlayMonitor {
    private var observers: [NSObjectProtocol] = []
    var changed: (() -> Void)?
    static func facts(screens: [UIScreen] = UIScreen.screens, audio: AVAudioSessionRouteDescription = AVAudioSession.sharedInstance().currentRoute) -> NPAirPlayFacts {
        NPAirPlayFacts(externalMirroring:screens.contains { $0.mirrored != nil }, airPlayAudio:audio.outputs.contains { $0.portType == .airPlay })
    }
    var snapshot: [String: Any] {
        let facts = Self.facts()
        return ["status":facts.status, "systemManaged":true, "externalMirroring":facts.externalMirroring, "airPlayAudio":facts.airPlayAudio, "exactReceiverIdentified":false]
    }
    func start() {
        precondition(Thread.isMainThread)
        guard observers.isEmpty else { return }
        for name in [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification, UIScreen.modeDidChangeNotification, AVAudioSession.routeChangeNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.changed?() })
        }
        changed?()
    }
    func stop() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
