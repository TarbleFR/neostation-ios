import Foundation
import GoogleCast

// Google Cast is a separate receiver protocol; never call a Chromecast an AirPlay receiver.
final class NPGoogleCast: NSObject, GCKDiscoveryManagerListener, GCKSessionManagerListener, GCKRemoteMediaClientListener, GCKRequestDelegate {
    private var initialized = false
    private var selected: String?
    private var ownsSession = false
    private var cancelling = false
    var changed: (() -> Void)?
    var onReady: (() -> Void)?
    var onPlayback: (() -> Void)?
    var onError: ((NPError) -> Void)?
    private var context: GCKCastContext { GCKCastContext.sharedInstance() }
    func startDiscovery() {
        if !initialized {
            let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
            options.disableDiscoveryAutostart = true
            options.disableAnalyticsLogging = true
            options.physicalVolumeButtonsWillControlDeviceVolume = false
            GCKCastContext.setSharedInstanceWith(options)
            context.discoveryManager.add(self); context.sessionManager.add(self); initialized = true
        }
        context.discoveryManager.startDiscovery(); changed?()
    }
    func stopDiscovery() { if initialized { context.discoveryManager.stopDiscovery() } }
    func didUpdateDeviceList() { changed?() }
    private var devices: [GCKDevice] {
        guard initialized else { return [] }
        return (0..<context.discoveryManager.deviceCount).map { context.discoveryManager.device(at: $0) }.filter { $0.isOnLocalNetwork && $0.hasCapabilities(.videoOut) }
    }
    var receivers: [[String: Any]] { devices.map { ["id": "cast:\($0.uniqueID)", "name": $0.friendlyName ?? "Chromecast", "kind": "cast"] } }
    func connect(_ id: String) {
        guard let device = devices.first(where: { "cast:\($0.uniqueID)" == id }) else { onError?(.receiverGone); return }
        // Do not take over a session started by another integration.
        guard context.sessionManager.currentCastSession == nil, selected == nil else { onError?(.busy); return }
        selected = device.uniqueID
        if !context.sessionManager.startSession(with: device) { selected = nil; onError?(.cast) }
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        guard selected == session.device.uniqueID else { return }
        ownsSession = true
        if cancelling { sessionManager.endSessionAndStopCasting(true); return }
        session.remoteMediaClient?.add(self); onReady?(); onReady = nil
    }
    func load(_ url: URL) {
        guard ownsSession, let session = context.sessionManager.currentCastSession, selected == session.device.uniqueID else { onError?(.cast); return }
        let media = GCKMediaInformationBuilder(contentURL: url)
        media.contentType = "application/vnd.apple.mpegurl"; media.streamType = .live
        media.hlsSegmentFormat = .FMP4; media.hlsVideoSegmentFormat = .FMP4
        let metadata = GCKMediaMetadata(metadataType: .generic); metadata.setString("NeoPlay", forKey: kGCKMetadataKeyTitle); media.metadata = metadata
        let request = GCKMediaLoadRequestDataBuilder(); request.mediaInformation = media.build(); request.autoplay = true
        session.remoteMediaClient?.loadMedia(with: request.build()).delegate = self
    }
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard ownsSession else { return }
        if mediaStatus?.playerState == .playing { onPlayback?() }
        if mediaStatus?.playerState == .idle && mediaStatus?.idleReason == .error { onError?(.cast) }
    }
    func request(_ request: GCKRequest, didFailWithError error: GCKError) { if ownsSession { NPLog.error("cast.request", error); onError?(.cast) } }
    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        guard selected == session.device.uniqueID else { return }; selected = nil; ownsSession = false; cancelling = false; onError?(.cast)
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        guard selected == session.device.uniqueID else { return }; selected = nil; ownsSession = false; cancelling = false; onError?(.network)
    }
    func stop() {
        onReady = nil; onPlayback = nil; onError = nil
        guard initialized else { return }
        let matches = context.sessionManager.currentCastSession?.device.uniqueID == selected
        context.sessionManager.currentCastSession?.remoteMediaClient?.remove(self)
        if matches && ownsSession { context.sessionManager.endSessionAndStopCasting(true) }
        if ownsSession { selected = nil; ownsSession = false; cancelling = false }
        else if selected != nil { cancelling = true }
    }
}
