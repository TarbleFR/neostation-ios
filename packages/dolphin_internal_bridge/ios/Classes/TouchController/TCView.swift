// Adapted from DolphiniOS 7cac5416. SPDX-License-Identifier: GPL-2.0-or-later
import UIKit

@objc class TCView: UIView {
  var real_view: UIView?
  @objc var port: Int = 0 {
    didSet { if let view = real_view { setPort(port, view: view) } }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    loadPad()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    loadPad()
  }

  private func loadPad() {
    let name = String(describing: type(of: self))
    guard let view = Bundle(for: TCView.self).loadNibNamed(name, owner: self)?.first as? UIView else { return }
    view.frame = bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.backgroundColor = .clear
    addSubview(view)
    real_view = view
    setPort(port, view: view)
  }

  private func setPort(_ port: Int, view: UIView) {
    for subview in view.subviews {
      switch subview {
      case let button as TCButton: button.port = port
      case let joystick as TCJoystick: joystick.port = port
      case let dpad as TCDirectionalPad: dpad.port = port
      default: setPort(port, view: subview)
      }
    }
  }
}
