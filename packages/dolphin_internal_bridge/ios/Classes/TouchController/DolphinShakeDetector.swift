// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// User acceleration is gravity-free, in g. Only intentional impulses fire.
/// No title-specific cheats, physics edits, tilt steering or auto-repeat.
struct DolphinShakeDetector {
  private var armed = true
  private var nextAllowed = -Double.infinity
  private var lastTimestamp = -Double.infinity

  mutating func reset() { self = DolphinShakeDetector() }

  mutating func sample(x: Double, y: Double, z: Double, timestamp: Double) -> Bool {
    guard x.isFinite, y.isFinite, z.isFinite, timestamp.isFinite,
          timestamp >= lastTimestamp else { return false }
    lastTimestamp = timestamp
    let magnitudeSquared = x*x + y*y + z*z
    guard magnitudeSquared.isFinite else { return false }
    if magnitudeSquared < 0.30*0.30 { armed = true }
    guard armed, timestamp >= nextAllowed, magnitudeSquared >= 0.90*0.90 else { return false }
    armed = false
    nextAllowed = timestamp + 0.30
    return true
  }
}

enum DolphinPhoneShakePolicy {
  static let preferenceKey = "NeoStation.Dolphin.PhoneShake.Enabled"
  static let preferenceChanged = "NeoStation.Dolphin.PhoneShakeChanged"
  static let touchPort = 4  // the existing first emulated Wiimote touchscreen
  static let shakeButtons = [132, 133, 134]
  static let pulseDuration = 0.12

  static func acceptsInput(wii: Bool, remoteLayout: Bool, sessionRunning: Bool,
                           visible: Bool, touchEnabled: Bool, appActive: Bool,
                           physicalController: Bool, enabled: Bool) -> Bool {
    // A gamepad hides the touch buttons, but the phone remains a valid motion
    // source. Menus still disable touchEnabled; background/Classic/GC stop it.
    return wii && remoteLayout && sessionRunning && (visible || physicalController) &&
           touchEnabled && appActive && enabled
  }
}
