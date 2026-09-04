import UIKit

@objc(DOLTouchOverlay) class DolphinTouchOverlay: UIView {
  private let wii: Bool
  private var pad: TCView?
  private var layoutName = ""

  @objc(initWithWii:) init(wii: Bool) {
    self.wii = wii
    super.init(frame: .zero)
    backgroundColor = .clear
    isMultipleTouchEnabled = true
    updateExtension("Nunchuk")
  }

  required init?(coder: NSCoder) { return nil }

  @objc func updateExtension(_ name: String) {
    let wanted = !wii ? "gc" : name == "Classic" ? "classic" : "wii"
    guard wanted != layoutName else { return }
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
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    pad?.frame = bounds
    if let remote = pad as? TCWiiPad {
      remote.recalculatePointerValues(new_rect: bounds, game_aspect: 16.0 / 9.0)
    }
  }
}
