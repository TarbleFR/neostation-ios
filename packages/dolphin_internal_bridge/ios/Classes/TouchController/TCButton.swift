// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

class TCButton: UIButton
{
  let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    
  @IBInspectable var controllerButton: Int = 0 // default: GC A button
  {
    didSet
    {
      updateImage()
    }
  }
  
  @IBInspectable var isAxis: Bool = false
  
  var port: Int = 0
  var useHapicTouch: Bool = true
  var lastForce: CGFloat = CGFloat.zero
  
  override init(frame: CGRect)
  {
    super.init(frame: frame)
    sharedInit()
  }
  
  required init?(coder: NSCoder)
  {
    super.init(coder: coder)
    sharedInit()
  }
  
  func sharedInit()
  {
    self.setTitle("", for: .normal)
    self.addTarget(self, action: #selector(buttonPressed), for: .touchDown)
    self.addTarget(self, action: #selector(buttonReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    
    // TODO: Setting for hapic touch analog triggers enabled
    self.useHapicTouch = self.traitCollection.forceTouchCapability == .available
  }
  
  func updateImage()
  {
    guard let buttonType = TCButtonType(rawValue: controllerButton) else { return }
    
    let buttonImage = getImage(named: buttonType.getImageName(), scale: buttonType.getButtonScale())
    self.setImage(buttonImage, for: .normal)
    
    let buttonPressedImage = getImage(named: buttonType.getImageName() + "_pressed", scale: buttonType.getButtonScale())
    self.setImage(buttonPressedImage, for: .selected)
  }
  
  func getImage(named: String, scale: CGFloat) -> UIImage
  {
    // In Interface Builder, the default bundle is not Dolphin's, so we must specify
    // the bundle for the image to load correctly
    guard let image = UIImage(named: named, in: Bundle(for: type(of: self)), compatibleWith: nil),
          image.size.width > 0, image.size.height > 0 else { return UIImage() }
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return UIGraphicsImageRenderer(size: newSize).image { _ in
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }.withRenderingMode(.alwaysOriginal)
  }
  
  @objc func buttonPressed()
  {
    isSelected = true
    if (isAxis && useHapicTouch)
    {
      return
    }
    
    hapticGenerator.impactOccurred()
    
    if (isAxis)
    {
      TCManagerInterface.setAxisValueFor(controllerButton, controller: port, value: 1.0)
    }
    else
    {
      TCManagerInterface.setButtonStateFor(controllerButton, controller: port, state: true)
    }
  }
  
  @objc func buttonReleased()
  {
    isSelected = false
    if (isAxis)
    {
      TCManagerInterface.setAxisValueFor(controllerButton, controller: port, value: 0.0)
    }
    else
    {
      TCManagerInterface.setButtonStateFor(controllerButton, controller: port, state: false)
    }
  }
  
  @objc override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?)
  {
    if (!isAxis || !useHapicTouch)
    {
      return
    }
    
    let touch = touches.first!
    let force = touch.force
    let maxForce = touch.maximumPossibleForce
    let percentage: Float = Float(force / maxForce);
    
    TCManagerInterface.setAxisValueFor(controllerButton, controller: port, value: percentage)
    
    if (self.lastForce != force && force == maxForce)
    {
      hapticGenerator.impactOccurred()
    }
    
    self.lastForce = force;
  }
  
}

