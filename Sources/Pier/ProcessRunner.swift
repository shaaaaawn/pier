import Foundation

enum ProcessRunner {
  struct Result {
    let stdout: String
    /// Captured too, because some CLIs report refusals here rather than on
    /// stdout — cmux's "Access denied" is the case that mattered: without it,
    /// a blocked integration was indistinguishable from an absent one.
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool

    /// stdout + stderr, for callers that just want to look for a message.
    var combined: String { stdout + stderr }
  }

  /// Run a process to completion, SIGKILLing it if it exceeds `timeout` seconds.
  /// Returns nil only if the process could not be launched at all.
  ///
  /// `environment` additions are the way to pass a secret: process arguments are
  /// world-readable via `ps`, so anything sensitive must travel out of band.
  static func run(
    _ path: String, _ arguments: [String], timeout: TimeInterval,
    environment: [String: String] = [:]
  ) -> Result? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if !environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
        new
      }
    }
    let pipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = pipe
    process.standardError = errPipe
    do {
      try process.run()
    } catch {
      return nil
    }

    let watchdog = DispatchWorkItem {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

    // Drain stderr concurrently: reading the pipes in sequence deadlocks if the
    // second one fills its 64K buffer while we're still blocked on the first.
    var errData = Data()
    let errDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      errDone.signal()
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    errDone.wait()
    process.waitUntilExit()
    watchdog.cancel()

    return Result(
      stdout: String(data: data, encoding: .utf8) ?? "",
      stderr: String(data: errData, encoding: .utf8) ?? "",
      exitCode: process.terminationStatus,
      timedOut: process.terminationReason == .uncaughtSignal
    )
  }
}
