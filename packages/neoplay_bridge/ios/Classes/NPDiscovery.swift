import Foundation

final class NPDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private let makeBrowser: () -> NetServiceBrowser
    private(set) var services: [String: NetService] = [:]
    var changed: (() -> Void)?
    var failed: (() -> Void)?
    init(makeBrowser: @escaping () -> NetServiceBrowser = { NetServiceBrowser() }) {
        self.makeBrowser = makeBrowser; super.init()
    }
    private func id(_ service: NetService) -> String { "windows:\(service.domain)\(service.name)" }
    func start() {
        stop(); let browser = makeBrowser(); self.browser = browser; browser.delegate = self
        browser.searchForServices(ofType: "_neoplay._tcp.", inDomain: "local.")
        NPLog.record("windows.discovery.requested")
    }
    func stop() {
        browser?.stop(); browser?.delegate = nil; browser = nil
        for service in services.values { service.stop(); service.delegate = nil }
        services.removeAll(); changed?()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard self.browser === browser, services.count < 64 else { return }
        services[id(service)] = service; service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard self.browser === browser else { return }; services.removeValue(forKey: id(service)); changed?()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard self.browser === browser else { return }
        var fields: [String: Any] = [:]
        if let domain = errorDict[NetService.errorDomain] { fields["domain"] = domain }
        if let code = errorDict[NetService.errorCode] { fields["code"] = code }
        NPLog.record("windows.discovery.failed", fields); failed?()
    }
    func netServiceDidResolveAddress(_ sender: NetService) { guard services[id(sender)] === sender else { return }; changed?() }
    var receivers: [[String: Any]] {
        services.compactMap { key, service in
            guard service.hostName != nil, service.port > 0, let data = service.txtRecordData() else { return nil }
            let txt = NetService.dictionary(fromTXTRecord: data)
            guard txt["v"] == Data("1".utf8), txt["kind"] == Data("windows".utf8) else { return nil }
            return ["id": key, "name": service.name, "kind": "windows"]
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }
}
