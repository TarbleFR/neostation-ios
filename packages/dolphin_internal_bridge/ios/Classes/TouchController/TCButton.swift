// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

class TCButton: UIButton {
  let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)

  @IBInspectable var controllerButton: Int = 0 {
    didSet { updateImage() }
  }
  @IBInspectable var isAxis: Bool = false
  var port: Int = 0
  var useHapicTouch: Bool = true
  var lastForce: CGFloat = .zero
  private var restingSize: CGSize?

  override var intrinsicContentSize: CGSize {
    return restingSize ?? super.intrinsicContentSize
  }

  override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
    guard let size = restingSize else { return super.imageRect(forContentRect: contentRect) }
    return CGRect(x: contentRect.midX - size.width * 0.5,
                  y: contentRect.midY - size.height * 0.5,
                  width: size.width, height: size.height)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    sharedInit()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    sharedInit()
  }

  override func awakeFromNib() {
    super.awakeFromNib()
    configureMomentaryAppearance()
    updateImage()
  }

  private func configureMomentaryAppearance() {
    // The resource adapter creates custom (not system/roundedRect) buttons.
    // Do this again after nib decoding so UIKit cannot restore a title/style.
    configuration = nil
    automaticallyUpdatesConfiguration = false
    changesSelectionAsPrimaryAction = false
    isSelected = false
    isExclusiveTouch = false
    setTitle(nil, for: .normal)
    adjustsImageWhenHighlighted = false
    imageView?.contentMode = .center
    contentEdgeInsets = .zero
    imageEdgeInsets = .zero
    titleEdgeInsets = .zero
  }

  private func sharedInit() {
    configureMomentaryAppearance()
    addTarget(self, action: #selector(buttonPressed), for: [.touchDown, .touchDragEnter])
    addTarget(self, action: #selector(buttonReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    useHapicTouch = traitCollection.forceTouchCapability == .available
  }

  private func centeredImage(_ image: UIImage, canvas: CGSize) -> UIImage {
    guard canvas.width > 0, canvas.height > 0 else { return image }
    return UIGraphicsImageRenderer(size: canvas).image { _ in
      image.draw(at: CGPoint(x: (canvas.width - image.size.width) * 0.5,
                             y: (canvas.height - image.size.height) * 0.5))
    }.withRenderingMode(.alwaysOriginal)
  }

  func updateImage() {
    guard let buttonType = TCButtonType(rawValue: controllerButton) else { return }
    let normal = getImage(named: buttonType.getImageName(), scale: buttonType.getButtonScale())
    let pressed = getImage(named: buttonType.getImageName() + "_pressed", scale: buttonType.getButtonScale())
    let canvas = CGSize(width: max(normal.size.width, pressed.size.width),
                        height: max(normal.size.height, pressed.size.height))
    restingSize = canvas
    setImage(centeredImage(normal, canvas: canvas), for: .normal)
    setImage(centeredImage(pressed, canvas: canvas), for: .highlighted)
    invalidateIntrinsicContentSize()
  }

  func getImage(named: String, scale: CGFloat) -> UIImage {
    guard let image = UIImage(named: named, in: Bundle(for: type(of: self)), compatibleWith: nil),
          image.size.width > 0, image.size.height > 0 else { return UIImage() }
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return UIGraphicsImageRenderer(size: size).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }.withRenderingMode(.alwaysOriginal)
  }

  @objc func buttonPressed() {
    if isAxis && useHapicTouch { return }
    hapticGenerator.impactOccurred()
    if isAxis {
      TCManagerInterface.setAxisValueFor(controllerButton, controller: port, value: 1.0)
    } else {
      TCManagerInterface.setButtonStateFor(controllerButton, controller: port, state: true)
    }
  }

  @objc func buttonReleased() {
    if isAxis {
      TCManagerInterface.setAxisValueFor(controllerButton, controller: port, value: 0.0)
    } else {
      TCManagerInterface.setButtonStateFor(controllerButton, controller: port, state: false)
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesMoved(touches, with: event)
    guard isAxis, useHapicTouch, let touch = touches.first,
          touch.maximumPossibleForce > 0 else { return }
    let force = touch.force
    let maxForce = touch.maximumPossibleForce
    let percentage = Float(max(0, min(1, force / maxForce)))
    TCManagerInterface.setAxisValueFor(controllerButton, controller: port, value: percentage)
    if lastForce != force && force == maxForce { hapticGenerator.impactOccurred() }
    lastForce = force
  }
}
