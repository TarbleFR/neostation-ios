import Foundation

/// Models Network.framework's serial completion queue. The first (log)
/// completion is held until the control send has been enqueued, reproducing the
/// ordering that previously made both completions wait behind sendLock.
private final class FakeConnection {
  private let completionQueue = DispatchQueue(
    label: "com.neogamelab.neostation.tests.reporter-completions"
  )
  private let controlEnqueued = DispatchSemaphore(value: 0)
  private var sendCount = 0

  func send(completion: @escaping (Error?) -> Void) {
    sendCount += 1
    let position = sendCount
    completionQueue.async {
      if position == 1 {
        precondition(
          self.controlEnqueued.wait(timeout: .now() + 1) == .success,
          "control send was not enqueued"
        )
      }
      completion(nil)
    }
  }

  func releaseFirstCompletion() {
    controlEnqueued.signal()
  }
}

private final class ReporterSendOrderHarness {
  private let connection = FakeConnection()
  private let sendLock = NSLock()
  private var pendingLogs = 0

  func sendLog() {
    sendLock.lock()
    pendingLogs += 1
    connection.send { [weak self] _ in
      guard let self else { return }
      self.sendLock.lock()
      self.pendingLogs -= 1
      self.sendLock.unlock()
    }
    sendLock.unlock()
  }

  func sendControl() -> Bool {
    let acknowledged = DispatchSemaphore(value: 0)

    // This is the production ordering under test: serialize enqueue, release
    // the shared lock, and only then wait for the authoritative completion.
    sendLock.lock()
    connection.send { _ in acknowledged.signal() }
    sendLock.unlock()
    connection.releaseFirstCompletion()

    return acknowledged.wait(timeout: .now() + 1) == .success
  }
}

private let reporter = ReporterSendOrderHarness()
reporter.sendLog()
precondition(
  reporter.sendControl(),
  "control acknowledgement was blocked behind the prior log completion"
)
print("PASS: RPCS3 reporter releases sendLock before control acknowledgement")
