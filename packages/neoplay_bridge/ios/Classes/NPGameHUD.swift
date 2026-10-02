import UIKit

final class NPBatteryHUDView: UIView {
    private let stack = UIStackView()
    override init(frame: CGRect) {
        super.init(frame:frame); isUserInteractionEnabled = false
        accessibilityIdentifier = "neoplay-controller-batteries"
        stack.spacing = 6; addSubview(stack)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func layoutSubviews() { super.layoutSubviews(); stack.frame = bounds }
    func configure(_ readings: [NPControllerBatteryReading], labels: [String:String], maximumWidth: CGFloat) -> CGSize {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for reading in readings.prefix(4) {
            let value = reading.value
            let pill = UIStackView(); pill.axis = .horizontal; pill.alignment = .center; pill.spacing = 4
            pill.isLayoutMarginsRelativeArrangement = true; pill.layoutMargins = UIEdgeInsets(top:6,left:8,bottom:6,right:8)
            pill.backgroundColor = UIColor.black.withAlphaComponent(0.7); pill.layer.cornerRadius = 12
            let symbol = UIImageView(image:UIImage(systemName:"gamecontroller.fill")); symbol.contentMode = .scaleAspectFit; symbol.tintColor = value.low ? .systemOrange : .white
            symbol.widthAnchor.constraint(equalToConstant:17).isActive = true; symbol.heightAnchor.constraint(equalToConstant:15).isActive = true
            let text = UILabel(); text.font = .monospacedDigitSystemFont(ofSize:12,weight:.semibold); text.textColor = .white
            let amount = value.percent.map { (labels["percent"] ?? "{value}%").replacingOccurrences(of:"{value}",with:String($0)) } ?? "—"
            text.text = (readings.count > 1 ? "\(reading.player) · " : "") + amount
            pill.addArrangedSubview(symbol); pill.addArrangedSubview(text)
            if value.charge == .charging {
                let charging = UIImageView(image:UIImage(systemName:"bolt.fill")); charging.tintColor = .systemGreen
                charging.widthAnchor.constraint(equalToConstant:10).isActive = true; pill.addArrangedSubview(charging)
            }
            let controller = (labels["controller"] ?? "{number}").replacingOccurrences(of:"{number}",with:String(reading.player))
            pill.isAccessibilityElement = true; pill.accessibilityLabel = [controller,reading.name,labels["battery"] ?? ""].filter { !$0.isEmpty }.joined(separator:", ")
            pill.accessibilityValue = [value.percent == nil ? labels["unavailable"] ?? "—" : amount, value.charge == .charging ? labels["charging"] ?? "" : "", value.low ? labels["low"] ?? "" : ""].filter { !$0.isEmpty }.joined(separator:", ")
            stack.addArrangedSubview(pill)
        }
        stack.axis = .horizontal
        var size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        if size.width > maximumWidth { stack.axis = .vertical; size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }
        return size
    }
}

final class NPGameHUD {
    private let monitor = NPControllerBatteryMonitor()
    private var labels: [String:String] = [:]
    private var active = false
    private var foreground = true
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private weak var anchor: UIButton?
    private let hud = NPBatteryHUDView()
    private var readings: [NPControllerBatteryReading] = []
    private var needsRebuild = true
    private var cachedWidth: CGFloat = 0
    private var cachedSize = CGSize.zero
    init() { monitor.changed = { [weak self] rows in self?.readings = rows; self?.needsRebuild = true; self?.update() } }
    func configure(active: Bool, labels: [String:String]) {
        precondition(Thread.isMainThread)
        needsRebuild = needsRebuild || self.labels != labels
        self.labels = labels; self.active = active
        if active && observers.isEmpty {
            foreground = UIApplication.shared.applicationState == .active
            observers.append(NotificationCenter.default.addObserver(forName:UIApplication.willResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.foreground = false; self?.reconcile() })
            observers.append(NotificationCenter.default.addObserver(forName:UIApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.foreground = true; self?.reconcile() })
        }
        if !active { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
        reconcile()
    }
    private func reconcile() {
        guard active && foreground else {
            timer?.invalidate(); timer = nil; monitor.stop(); anchor = nil; hud.removeFromSuperview(); return
        }
        monitor.start()
        if timer == nil {
            let timer = Timer(timeInterval:1,repeats:true) { [weak self] _ in self?.update() }; timer.tolerance = 0.2
            RunLoop.main.add(timer,forMode:.common); self.timer = timer
        }
        update()
    }
    private func update() {
        guard active, foreground, !readings.isEmpty else { hud.removeFromSuperview(); return }
        if anchor == nil || !NPGameHUDAnchor.visible(anchor!) {
            anchor = nil; hud.removeFromSuperview()
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive && $0.session.role == .windowApplication }.flatMap(\.windows).filter { !$0.isHidden && $0.alpha > 0 && $0.windowLevel < .alert }.sorted { $0.windowLevel > $1.windowLevel }
            for window in windows.prefix(8) { if let found = NPGameHUDAnchor.find(in:window) { anchor = found; break } }
        }
        guard let anchor, NPGameHUDAnchor.visible(anchor), let parent = anchor.superview else { hud.removeFromSuperview(); return }
        let safe = parent.safeAreaLayoutGuide.layoutFrame.insetBy(dx:4,dy:4)
        if needsRebuild || cachedWidth != safe.width {
            cachedSize = hud.configure(readings,labels:labels,maximumWidth:safe.width)
            cachedWidth = safe.width; needsRebuild = false
        }
        let size = cachedSize
        var blockers = parent.subviews.filter { $0 !== hud && $0 !== anchor && !$0.isHidden && $0.alpha > 0.05 && ($0 is UIControl || $0 is UILabel) }.map { $0.frame }
        // Reserve the independent NeoPlay stop control in its overlay window too.
        for window in parent.window?.windowScene?.windows ?? [] where !window.isHidden && window !== parent.window {
            for view in window.rootViewController?.viewIfLoaded?.subviews ?? [] where view.accessibilityIdentifier == "neoplay-stop-stream" && !view.isHidden {
                blockers.append(parent.convert(view.bounds,from:view))
            }
        }
        guard let frame = NPCompanionPlacement.frame(anchor:anchor.frame,safe:safe,size:size,obstacles:blockers) else { hud.removeFromSuperview(); return }
        if hud.superview !== parent { hud.removeFromSuperview(); parent.addSubview(hud) }
        hud.frame = frame
        if parent.subviews.last !== hud { parent.bringSubviewToFront(hud) }
    }
    deinit { timer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
}
