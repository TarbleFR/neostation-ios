// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

class TCWiiPad: TCView, UIGestureRecognizerDelegate {
  var mode: TCWiiTouchIRMode = .none
  
  var gameCenterX: CGFloat = 0
  var gameCenterY: CGFloat = 0
  var gameWidthHalfInv: CGFloat = 0
  var gameHeightHalfInv: CGFloat = 0
  
  var touchStartPoint: CGPoint = CGPoint(x: 0, y: 0)
  var oldX: CGFloat = 0
  var oldY: CGFloat = 0
  private var pointerX: CGFloat = 0
  private var pointerY: CGFloat = 0
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    installPointer()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    installPointer()
  }

  private func installPointer() {
    
    // Register our "long press" gesture recognizer
    let pressHandler = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
    pressHandler.minimumPressDuration = 0
    pressHandler.numberOfTouchesRequired = 1
    pressHandler.cancelsTouchesInView = false
    pressHandler.delegate = self
    self.real_view?.addGestureRecognizer(pressHandler)
  }
  
  @objc func recalculatePointerValues(new_rect: CGRect, game_aspect: CGFloat) {
    guard new_rect.width > 0, new_rect.height > 0,
          game_aspect.isFinite, game_aspect > 0 else {
      gameWidthHalfInv = 0
      gameHeightHalfInv = 0
      return
    }
    gameCenterX = new_rect.midX
    gameCenterY = new_rect.midY

    var gameWidth = new_rect.width
    var gameHeight = new_rect.height

    // Adjusting for device's black bars.
    let surfaceAR = gameWidth / gameHeight
    let gameAR = game_aspect
    if (gameAR <= surfaceAR) {
        // Black bars on left/right
        gameWidth = gameHeight * gameAR
    } else {
        // Black bars on top/bottom
        gameHeight = gameWidth / gameAR
    }

    gameWidthHalfInv = 1 / (gameWidth * 0.5)
    gameHeightHalfInv = 1 / (gameHeight * 0.5)
  }
  
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if (touch.view == self.real_view) {
      return true
    }
    
    return false
  }
  
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    if (otherGestureRecognizer is UIScreenEdgePanGestureRecognizer) {
      return true
    }
    
    return false
  }
  
  @objc func handleLongPress(gesture: UILongPressGestureRecognizer) {
    if (mode == .none || gameWidthHalfInv == 0 || gameHeightHalfInv == 0) {
      return
    }

    // A cancelled gesture may report the Control Centre/menu swipe location.
    // Keep the last valid pointer position when the finger leaves the screen;
    // only an active touch may move it.
    switch gesture.state {
    case .ended, .cancelled, .failed:
      if mode == .drag {
        oldX = pointerX
        oldY = pointerY
      }
      return
    case .began, .changed:
      break
    default:
      return
    }

    let point = gesture.location(in: self)
    guard point.x.isFinite, point.y.isFinite else { return }
    if gesture.state == .began {
      touchStartPoint = point
    }
    
    var x: CGFloat, y: CGFloat
    
    if (mode == .follow) {
      x = (point.x - gameCenterX) * gameWidthHalfInv
      y = (point.y - gameCenterY) * gameHeightHalfInv
    } else {
      x = oldX + (point.x - touchStartPoint.x) * gameWidthHalfInv
      y = oldY + (point.y - touchStartPoint.y) * gameHeightHalfInv
    }
    
    pointerX = max(-1, min(1, x))
    pointerY = max(-1, min(1, y))
    let axisStartIdx = TCButtonType.wiiInfrared
    for (i, axis) in [pointerY, pointerY, pointerX, pointerX].enumerated() {
      TCManagerInterface.setAxisValueFor(axisStartIdx.rawValue + i + 1, controller: self.port, value: Float(axis))
    }
  }
  
  @objc func setTouchIRMode(_ newMode: TCWiiTouchIRMode) {
    self.mode = newMode
  }
  
  @objc func resetPointer() {
    touchStartPoint = CGPoint(x: 0, y: 0)
    oldX = 0
    oldY = 0
    pointerX = 0
    pointerY = 0
  }
}
