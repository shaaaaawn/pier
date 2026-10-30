import Foundation

/// The refresh's three process probes. A failed one is a gap in what Pier
/// knows, not news that everything it lists has stopped.
enum ProcessProbe: String, CaseIterable, Sendable {
  case sockets = "lsof"
  case processTable = "ps (table)"
  case commandLines = "ps (command lines)"
}

/// Keeps each probe's last good output and stands it in for a failed run.
///
/// Before this, a probe that timed out or couldn't launch turned into "" and
/// the refresh read it as an empty machine: every MCP server and simulator
/// "stopped" at once, then "started" 30 s later, into the event feed and the
/// badge. Seen on a loaded Mac 9 times in one afternoon. A stand-in is at most
/// `maxAge` old — past that, an empty list is the honest answer.
///
/// Called from the refresh's background queue, so `lock` guards the cache.
final class ProbeFallback: @unchecked Sendable {
  static let maxAge: TimeInterval = 120

  private struct Good {
    let output: String
    let at: Date
  }

  private let lock = NSLock()
  private var good: [ProcessProbe: Good] = [:]
  /// Why each probe is currently failing — so the log gets one line when a
  /// probe breaks and one when it recovers, not one per refresh.
  private var failing: [ProcessProbe: String] = [:]

  /// Why a result can't be trusted, or nil when it can. Empty output counts:
  /// every probe here lists at least launchd or its own socket, so "nothing"
  /// is never a real answer. lsof's exit 1 with output is normal, so the exit
  /// code alone isn't a failure.
  static func failure(_ result: ProcessRunner.Result?) -> String? {
    guard let result else { return "could not launch" }
    if result.timedOut { return "timed out" }
    if result.stdout.allSatisfy(\.isWhitespace) {
      return result.exitCode == 0 ? "no output" : "exit \(result.exitCode), no output"
    }
    return nil
  }

  /// The output to use for `probe` this refresh: the result itself when it's
  /// good, else the last good output if it's recent enough, else "".
  func output(
    _ probe: ProcessProbe, _ result: ProcessRunner.Result?, now: Date = Date(),
    log: (String) -> Void = { PierLog.shared.log($0) }
  ) -> String {
    let reason = Self.failure(result)
    lock.lock()
    defer { lock.unlock() }
    let wasFailing = failing[probe]
    guard let reason else {
      if wasFailing != nil { log("\(probe.rawValue) probe recovered") }
      failing[probe] = nil
      let output = result?.stdout ?? ""
      good[probe] = Good(output: output, at: now)
      return output
    }
    failing[probe] = reason
    let fallback = good[probe].flatMap { now.timeIntervalSince($0.at) <= Self.maxAge ? $0 : nil }
    if wasFailing == nil {
      log(
        "\(probe.rawValue) probe failed (\(reason)); "
          + (fallback == nil ? "nothing recent to stand in" : "using the last good output"))
    }
    return fallback?.output ?? ""
  }
}

extension MonitorSnapshot {
  /// This snapshot with each unreachable engine's containers copied from
  /// `previous`, for the event diff.
  ///
  /// An engine that stops answering — Docker Desktop busy, `docker ps` timing
  /// out under load — lists no containers, and the diff read that as every
  /// running container stopping. Its containers are unknown, not stopped:
  /// carrying the last known rows forward makes the diff say nothing until the
  /// engine answers again, and then it reports whatever really changed.
  func carryingContainers(
    of unreachable: Set<ActivityKind>, from previous: MonitorSnapshot?
  ) -> MonitorSnapshot {
    guard let previous, !unreachable.isEmpty else { return self }
    var copy = self
    copy.activity =
      activity.filter { !unreachable.contains($0.kind) }
      + previous.activity.filter { unreachable.contains($0.kind) }
    return copy
  }
}
