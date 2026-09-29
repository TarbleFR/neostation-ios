// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMotion
import Foundation

/// One per live Wii touchscreen. All state and emissions belong to main.
final class DolphinPhoneShake {
  private let manager = CMMotionManager()
  private let emit: (Bool) -> Void
  private var detector = DolphinShakeDetector()
  private var active = false
  private var held = false
  private var generation: UInt64 = 0
  private var release: DispatchWorkItem?

  init(emit: @escaping (Bool) -> Void) { self.emit = emit }

  func setActive(_ value: Bool) {
    precondition(Thread.isMainThread)
    guard value != active else { return }
    if !value { stop(); return }
    guard manager.isDeviceMotionAvailable else { return }
    generation &+= 1
    let ticket = generation
    active = true
    detector.reset()
    manager.deviceMotionUpdateInterval = 1.0 / 100.0
    manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
      guard let self = self, self.active, self.generation == ticket else { return }
      guard error == nil, let motion = motion else { self.stop(); return }
      // A blocked UI must never play a queue of old gestures after resuming.
      let age = ProcessInfo.processInfo.systemUptime - motion.timestamp
      guard age >= -0.05, age < 0.10 else { return }
      let a = motion.userAcceleration
      guard self.detector.sample(x: a.x, y: a.y, z: a.z, timestamp: motion.timestamp) else { return }
      self.held = true
      self.emit(true)
      self.release?.cancel()
      let release = DispatchWorkItem { [weak self] in
        guard let self = self, self.generation == ticket else { return }
        self.releaseButtons()
      }
      self.release = release
      DispatchQueue.main.asyncAfter(deadline: .now() + DolphinPhoneShakePolicy.pulseDuration,
                                    execute: release)
    }
  }

  private func releaseButtons() {
    if held { held = false; emit(false) }
  }

  func stop() {
    generation &+= 1
    active = false
    manager.stopDeviceMotionUpdates()
    release?.cancel()
    release = nil
    releaseButtons()
    detector.reset()
  }

  deinit { stop() }
}
