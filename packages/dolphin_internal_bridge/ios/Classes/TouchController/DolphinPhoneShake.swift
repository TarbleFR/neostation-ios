// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMotion
import Foundation

/// One per live Wii Remote. Sensor processing and releases must not depend on
/// the UI queue: the emulator can keep polling inputs while UIKit is busy.
final class DolphinPhoneShake {
  private let manager = CMMotionManager()
  private let inputQueue = DispatchQueue(label: "NeoStation.Dolphin.PhoneShake", qos: .userInteractive)
  private let inputQueueKey = DispatchSpecificKey<Bool>()
  private let sensorQueue = OperationQueue()
  private let requestLock = NSLock()
  private var requestedActive = false
  private var requestGeneration: UInt64 = 0
  private let emit: (Bool) -> Void
  private let prepare: () -> Bool
  private let unavailable: () -> Void
  private var detector = DolphinShakeDetector()
  private var active = false
  private var held = false
  private var generation: UInt64 = 0
  private var release: DispatchWorkItem?

  init(prepare: @escaping () -> Bool = { true },
       unavailable: @escaping () -> Void = {}, emit: @escaping (Bool) -> Void) {
    self.emit = emit
    self.prepare = prepare
    self.unavailable = unavailable
    inputQueue.setSpecific(key: inputQueueKey, value: true)
    sensorQueue.name = "NeoStation.Dolphin.PhoneShake.Sensor"
    sensorQueue.qualityOfService = .userInteractive
    sensorQueue.maxConcurrentOperationCount = 1
    sensorQueue.underlyingQueue = inputQueue
  }

  private func withInputQueue(_ body: () -> Void) {
    if DispatchQueue.getSpecific(key: inputQueueKey) == true { body() }
    else { inputQueue.sync(execute: body) }
  }

  func setActive(_ value: Bool) {
    precondition(Thread.isMainThread)
    requestLock.lock()
    guard value != requestedActive else { requestLock.unlock(); return }
    requestedActive = value
    requestGeneration &+= 1
    let ticket = requestGeneration
    requestLock.unlock()
    // Native launch can be waiting on main. Route setup must never make main
    // wait in turn for the emulator's serial runtime queue.
    inputQueue.async { [weak self] in
      guard let self = self, self.isCurrentRequest(ticket, active: value) else { return }
      if value { self.updateActive(ticket: ticket) }
      else { self.stopOnInputQueue() }
    }
  }

  private func isCurrentRequest(_ ticket: UInt64, active value: Bool) -> Bool {
    requestLock.lock()
    defer { requestLock.unlock() }
    return requestGeneration == ticket && requestedActive == value
  }

  func refreshRouting() {
    // Called after Dolphin has refreshed its effective input profile. A GC
    // notification can precede publication of the donor's new MFi device.
    // Re-qualification must not reset shake cooldown/rearming or sensors.
    inputQueue.async { [weak self] in
      guard let self = self else { return }
      self.requestLock.lock()
      let requested = self.requestedActive
      let ticket = self.requestGeneration
      self.requestLock.unlock()
      guard requested else { return }
      // A failed initial route may become valid after the donor publishes its
      // physical profile. Retry activation on the actual profile refresh.
      if !self.active { self.updateActive(ticket: ticket); return }
      // Preparation can wait on native configuration work. Never lengthen a
      // held 120 ms pulse while that serial runtime work is pending.
      self.release?.cancel()
      self.release = nil
      self.releaseButtons()
      let ready = self.prepare()
      guard self.isCurrentRequest(ticket, active: true) else { return }
      if !ready { self.stopOnInputQueue() }
    }
  }

  private func updateActive(ticket: UInt64) {
    if active { stopOnInputQueue() }
    guard manager.isDeviceMotionAvailable else { unavailable(); return }
    guard prepare() else { return }
    guard isCurrentRequest(ticket, active: true) else { return }
    generation = ticket
    active = true
    detector.reset()
    manager.deviceMotionUpdateInterval = 1.0 / 100.0
    manager.startDeviceMotionUpdates(to: sensorQueue) { [weak self] motion, error in
      guard let self = self, self.active, self.generation == ticket,
            self.isCurrentRequest(ticket, active: true) else { return }
      guard error == nil, let motion = motion else { self.unavailable(); self.stop(); return }
      // Drop a backlog on the sensor queue; UI stalls do not delay this queue.
      let age = ProcessInfo.processInfo.systemUptime - motion.timestamp
      guard age >= -0.05, age < 0.10 else { return }
      let a = motion.userAcceleration
      guard self.detector.sample(x: a.x, y: a.y, z: a.z, timestamp: motion.timestamp) else { return }
      self.requestLock.lock()
      guard self.requestGeneration == ticket && self.requestedActive else {
        self.requestLock.unlock()
        return
      }
      self.held = true
      self.emit(true)
      self.requestLock.unlock()
      self.release?.cancel()
      let release = DispatchWorkItem { [weak self] in
        guard let self = self, self.generation == ticket else { return }
        self.releaseButtons()
      }
      self.release = release
      self.inputQueue.asyncAfter(deadline: .now() + DolphinPhoneShakePolicy.pulseDuration,
                                    execute: release)
    }
  }

  private func releaseButtons() {
    if held { held = false; emit(false) }
  }

  func stop() {
    requestLock.lock()
    requestedActive = false
    requestGeneration &+= 1
    requestLock.unlock()
    if DispatchQueue.getSpecific(key: inputQueueKey) == true { stopOnInputQueue() }
    else { inputQueue.async { [weak self] in self?.stopOnInputQueue() } }
  }

  private func stopOnInputQueue() {
    generation &+= 1
    active = false
    manager.stopDeviceMotionUpdates()
    release?.cancel()
    release = nil
    releaseButtons()
    detector.reset()
  }

  deinit { withInputQueue { stopOnInputQueue() } }
}
