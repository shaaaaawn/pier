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

    // Read both pipes with poll() under a deadline, never `readDataToEndOfFile`.
    // EOF only arrives when *every* holder of a pipe's write end has closed it,
    // and a CLI that starts a background helper (`docker desktop start`,
    // `container system start`) passes its stdio down. Killing the CLI then
    // didn't end the read: the call never returned, its caller never completed,
    // and inside `refresh()` that left `isRefreshing` set — the panel froze
    // until relaunch. Now the read ends at the deadline, or shortly after the
    // process itself exits, whoever still holds the pipe.
    let output = drain(
      [pipe.fileHandleForReading.fileDescriptor, errPipe.fileHandleForReading.fileDescriptor],
      deadline: Date().addingTimeInterval(timeout + Self.killGrace),
      isRunning: { process.isRunning })
    process.waitUntilExit()
    watchdog.cancel()
    let data = output[0]
    let errData = output[1]

    return Result(
      stdout: String(data: data, encoding: .utf8) ?? "",
      stderr: String(data: errData, encoding: .utf8) ?? "",
      exitCode: process.terminationStatus,
      timedOut: process.terminationReason == .uncaughtSignal
    )
  }

  /// After the process exits (or is killed at the timeout), how long to keep
  /// reading for output still in flight before giving up on a pipe that an
  /// orphaned child is holding open.
  static let killGrace: TimeInterval = 0.3

  /// Read every fd until EOF on all of them, or `deadline`, or `killGrace`
  /// after `isRunning` turns false — whichever comes first. Single-threaded:
  /// poll() multiplexes both pipes, so neither can fill and stall the other.
  static func drain(
    _ fds: [Int32], deadline: Date, isRunning: () -> Bool
  ) -> [Data] {
    var data = Array(repeating: Data(), count: fds.count)
    var open = Set(fds.indices)
    var exitedAt: Date?
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while !open.isEmpty {
      let now = Date()
      if now >= deadline { break }
      if exitedAt == nil, !isRunning() { exitedAt = now }
      if let exitedAt, now.timeIntervalSince(exitedAt) >= killGrace { break }
      var pollfds = open.sorted().map { pollfd(fd: fds[$0], events: Int16(POLLIN), revents: 0) }
      // Wake at least every 100 ms to notice the process exiting.
      let wait = Int32(min(100, max(1, deadline.timeIntervalSince(now) * 1000)))
      let ready = poll(&pollfds, nfds_t(pollfds.count), wait)
      if ready < 0 {
        if errno == EINTR { continue }
        break
      }
      for (slot, index) in open.sorted().enumerated() where pollfds[slot].revents != 0 {
        let count = read(fds[index], &buffer, buffer.count)
        if count > 0 {
          data[index].append(contentsOf: buffer[0..<count])
        } else if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) {
          open.remove(index)
        }
      }
    }
    return data
  }
}
