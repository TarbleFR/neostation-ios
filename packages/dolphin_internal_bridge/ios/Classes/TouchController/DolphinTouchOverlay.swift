import UIKit
import GameController

@objc(DOLTouchOverlay) public class DolphinTouchOverlay: UIView {
  private let wii: Bool
  private var pad: TCView?
  private var layoutName = ""
  @objc public var sessionInputActive = false { didSet { refreshPhoneShake() } }
  private var appActive = UIApplication.shared.applicationState == .active
  private lazy var phoneShake = DolphinPhoneShake { pressed in
    for button in DolphinPhoneShakePolicy.shakeButtons {
      TCManagerInterface.setButtonStateFor(button,
        controller: DolphinPhoneShakePolicy.touchPort, state: pressed)
    }
  }

  public override var isHidden: Bool { didSet { refreshPhoneShake() } }
  public override var isUserInteractionEnabled: Bool { didSet { refreshPhoneShake() } }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    refreshPhoneShake()
  }

  @objc private func environmentChanged(_ notification: Notification) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.environmentChanged(notification) }
      return
    }
    if notification.name == UIApplication.willResignActiveNotification { appActive = false }
    if notification.name == UIApplication.didBecomeActiveNotification { appActive = true }
    refreshPhoneShake()
  }

  private func refreshPhoneShake() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.refreshPhoneShake() }
      return
    }
    let preference = UserDefaults.standard.object(forKey: DolphinPhoneShakePolicy.preferenceKey)
    let enabled = (preference as? Bool) ?? true
    phoneShake.setActive(DolphinPhoneShakePolicy.acceptsInput(wii: wii,
      remoteLayout: layoutName == "wii", sessionRunning: sessionInputActive,
      visible: window != nil && !isHidden, touchEnabled: isUserInteractionEnabled,
      appActive: appActive, physicalController: !GCController.controllers().isEmpty,
      enabled: enabled))
  }

  @objc(initWithWii:) public init(wii: Bool) {
    self.wii = wii
    super.init(frame: .zero)
    backgroundColor = .clear
    isMultipleTouchEnabled = true
    updateExtension("Nunchuk")
    for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
                 NSNotification.Name.GCControllerDidConnect, NSNotification.Name.GCControllerDidDisconnect,
                 Notification.Name(DolphinPhoneShakePolicy.preferenceChanged)] {
      NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged(_:)),
                                             name: name, object: nil)
    }
  }

  public required init?(coder: NSCoder) { return nil }

  deinit { phoneShake.stop(); NotificationCenter.default.removeObserver(self) }

  @objc public func updateExtension(_ name: String) {
    let wanted = !wii ? "gc" : name == "Classic" ? "classic" : "wii"
    guard wanted != layoutName else { return }
    phoneShake.stop()
    layoutName = wanted
    pad?.removeFromSuperview()
    let view: TCView
    if wanted == "gc" { view = TCGameCubePad(frame: bounds) }
    else if wanted == "classic" { view = TCClassicWiiPad(frame: bounds) }
    else { view = TCWiiPad(frame: bounds) }
    view.port = wii ? 4 : 0
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.backgroundColor = .clear
    if let remote = view as? TCWiiPad { remote.setTouchIRMode(.follow) }
    addSubview(view)
    pad = view
    refreshPhoneShake()
    setNeedsLayout()
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    pad?.frame = bounds
    if let remote = pad as? TCWiiPad {
      remote.recalculatePointerValues(new_rect: bounds, game_aspect: 16.0 / 9.0)
    }
  }
}
