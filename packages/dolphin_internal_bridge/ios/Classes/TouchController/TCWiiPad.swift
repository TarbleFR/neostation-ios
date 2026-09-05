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

  var touchStartPoint: CGPoint = .zero
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
    guard let surface = real_view else { return }
    isMultipleTouchEnabled = true
    surface.isMultipleTouchEnabled = true
    // A background sibling cannot receive touches belonging to controller
    // buttons, their labels, the D-pad or the Nunchuk's gesture recognizer.
    let pointerSurface = UIView(frame: surface.bounds)
    pointerSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    pointerSurface.backgroundColor = .clear
    pointerSurface.isMultipleTouchEnabled = true
    pointerSurface.accessibilityIdentifier = "dolphin-wii-pointer-surface"
    surface.insertSubview(pointerSurface, at: 0)

    let pressHandler = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
    pressHandler.minimumPressDuration = 0
    pressHandler.numberOfTouchesRequired = 1
    pressHandler.cancelsTouchesInView = false
    pressHandler.delaysTouchesBegan = false
    pressHandler.delaysTouchesEnded = false
    pressHandler.delegate = self
    pointerSurface.addGestureRecognizer(pressHandler)
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
    if game_aspect <= gameWidth / gameHeight {
      gameWidth = gameHeight * game_aspect
    } else {
      gameHeight = gameWidth / game_aspect
    }
    gameWidthHalfInv = 1 / (gameWidth * 0.5)
    gameHeightHalfInv = 1 / (gameHeight * 0.5)
  }

  private func isInteractiveControllerView(_ view: UIView?) -> Bool {
    var candidate = view
    while let current = candidate, current !== real_view {
      if current is UIControl || current is TCJoystick || current is TCDirectionalPad {
        return true
      }
      candidate = current.superview
    }
    return false
  }

  private func pointOverlapsInteractiveControl(_ point: CGPoint, in root: UIView) -> Bool {
    for subview in root.subviews where !subview.isHidden && subview.alpha > 0.01 {
      if subview is UIControl || subview is TCJoystick || subview is TCDirectionalPad {
        let frame = subview.convert(subview.bounds, to: self).insetBy(dx: -6, dy: -6)
        if frame.contains(point) { return true }
      }
      if pointOverlapsInteractiveControl(point, in: subview) { return true }
    }
    return false
  }

  // The delegate and regression tests share the real hit-ownership decision.
  // A button, D-pad or stick touch must never also write Wii IR axes.
  @objc(acceptsPointerAt:hitView:)
  func acceptsPointer(at point: CGPoint, hitView: UIView?) -> Bool {
    guard let surface = real_view, mode != .none,
          point.x.isFinite, point.y.isFinite, bounds.contains(point) else { return false }
    if isInteractiveControllerView(hitView) { return false }
    return !pointOverlapsInteractiveControl(point, in: surface)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    // Additional fingers must not shift the pointer gesture's centroid.
    guard gestureRecognizer.numberOfTouches == 0, let surface = real_view else { return false }
    let point = touch.location(in: self)
    let hit = surface.hitTest(touch.location(in: surface), with: nil)
    return acceptsPointer(at: point, hitView: touch.view) &&
           acceptsPointer(at: point, hitView: hit)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    // Different fingers may aim and use the Nunchuk/D-pad simultaneously.
    return isInteractiveControllerView(otherGestureRecognizer.view)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return otherGestureRecognizer is UIScreenEdgePanGestureRecognizer
  }

  @objc func handleLongPress(gesture: UILongPressGestureRecognizer) {
    guard mode != .none, gameWidthHalfInv != 0, gameHeightHalfInv != 0 else { return }
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
    // Accepted touches on the game surface position the pointer immediately.
    // Control touches have already been rejected by the delegate above.
    let x: CGFloat
    let y: CGFloat
    if mode == .follow {
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
      TCManagerInterface.setAxisValueFor(axisStartIdx.rawValue + i + 1, controller: port, value: Float(axis))
    }
  }

  @objc func setTouchIRMode(_ newMode: TCWiiTouchIRMode) {
    mode = newMode
  }

  @objc func resetPointer() {
    touchStartPoint = .zero
    oldX = 0
    oldY = 0
    pointerX = 0
    pointerY = 0
  }
}
