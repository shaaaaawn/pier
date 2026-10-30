import Foundation
import XCTest

@testable import Pier

/// A probe that fails is a gap in what Pier knows — never news that the things
/// it lists have stopped. Replays the afternoon that logged `peaceful_edison`
/// (up 4 days) stopping and starting nine times.
final class ProbeFailureTests: XCTestCase {
  private let t = Date(timeIntervalSince1970: 1_000)

  private func result(_ stdout: String, exit: Int32 = 0, timedOut: Bool = false)
    -> ProcessRunner.Result
  {
    ProcessRunner.Result(stdout: stdout, stderr: "", exitCode: exit, timedOut: timedOut)
  }

  private func port(_ port: Int, _ name: String, dev: DevServer? = nil) -> PortEntry {
    var entry = PortEntry(
      pid: 100, port: port, proto: .tcp, processName: name, user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .none)
    entry.dev = dev
    return entry
  }

  private func container(_ name: String, running: Bool) -> ActivityEntry {
    ActivityEntry(kind: .docker, name: name, detail: "", isRunning: running)
  }

  // MARK: - What counts as a failed probe

  func testFailureReasons() {
    XCTAssertEqual(ProbeFallback.failure(nil), "could not launch")
    XCTAssertEqual(ProbeFallback.failure(result("1 launchd", timedOut: true)), "timed out")
    XCTAssertEqual(ProbeFallback.failure(result("")), "no output")
    XCTAssertEqual(ProbeFallback.failure(result(" \n", exit: 1)), "exit 1, no output")
    XCTAssertNil(ProbeFallback.failure(result("1 launchd\n")))
    // lsof exits 1 for a socket it couldn't stat while still listing the rest.
    XCTAssertNil(ProbeFallback.failure(result("node 42 dev 21u IPv4 TCP *:3000 (LISTEN)", exit: 1)))
  }

  // MARK: - Standing in the last good output

  func testFailedProbeReadsAsItsLastGoodOutput() {
    let fallback = ProbeFallback()
    var lines: [String] = []
    let log = { (line: String) in lines.append(line) }
    XCTAssertEqual(
      fallback.output(.commandLines, result("1 root launchd\n"), now: t, log: log),
      "1 root launchd\n")
    XCTAssertEqual(
      fallback.output(.commandLines, nil, now: t.addingTimeInterval(30), log: log),
      "1 root launchd\n")
    XCTAssertEqual(
      fallback.output(.commandLines, result(""), now: t.addingTimeInterval(60), log: log),
      "1 root launchd\n")
    // One line when it breaks, one when it recovers — not one per refresh.
    XCTAssertEqual(
      lines, ["ps (command lines) probe failed (could not launch); using the last good output"])
    _ = fallback.output(
      .commandLines, result("2 root other\n"), now: t.addingTimeInterval(90), log: log)
    XCTAssertEqual(lines.last, "ps (command lines) probe recovered")
    XCTAssertEqual(lines.count, 2)
  }

  /// Past `maxAge` the stand-in is a guess, and an empty list is the honest answer.
  func testStandInExpires() {
    let fallback = ProbeFallback()
    _ = fallback.output(.sockets, result("listing"), now: t, log: { _ in })
    let late = t.addingTimeInterval(ProbeFallback.maxAge + 1)
    XCTAssertEqual(fallback.output(.sockets, nil, now: late, log: { _ in }), "")
  }

  func testProbesAreIndependent() {
    let fallback = ProbeFallback()
    _ = fallback.output(.sockets, result("sockets"), now: t, log: { _ in })
    XCTAssertEqual(fallback.output(.processTable, nil, now: t, log: { _ in }), "")
  }

  // MARK: - An unreachable engine's containers are unknown, not stopped

  func testUnreachableEngineStopsNothing() {
    let up = MonitorSnapshot(activity: [container("peaceful_edison", running: true)])
    // `docker ps` fails: no containers listed this refresh.
    let gap = MonitorSnapshot().carryingContainers(of: [.docker], from: up)
    XCTAssertEqual(EventDiff.between(old: up, new: gap, at: t), [])
    // It answers again with the container still up: nothing started either.
    let back = MonitorSnapshot(activity: [container("peaceful_edison", running: true)])
    XCTAssertEqual(EventDiff.between(old: gap, new: back, at: t), [])
  }

  /// What really changed while the engine was silent is still reported, once
  /// it answers.
  func testRealStopDuringTheGapSurfacesOnRecovery() {
    let up = MonitorSnapshot(activity: [container("peaceful_edison", running: true)])
    let gap = MonitorSnapshot().carryingContainers(of: [.docker], from: up)
    let back = MonitorSnapshot(activity: [container("peaceful_edison", running: false)])
    let events = EventDiff.between(old: gap, new: back, at: t)
    XCTAssertEqual(events.map(\.action), [.stopped])
  }

  /// Only the silent engine is carried; the other one's changes are live.
  func testCarryIsPerEngine() {
    let apple = ActivityEntry(kind: .apple, name: "web", detail: "", isRunning: true)
    let up = MonitorSnapshot(activity: [container("peaceful_edison", running: true), apple])
    let gap = MonitorSnapshot().carryingContainers(of: [.docker], from: up)
    let events = EventDiff.between(old: up, new: gap, at: t)
    XCTAssertEqual(events.map(\.subject), [.container(.apple, "web")])
  }

  // MARK: - Ephemeral ports aren't news

  func testEphemeralPortChurnIsQuiet() {
    let before = MonitorSnapshot(ports: [port(64081, "Google Chrome")])
    let after = MonitorSnapshot(ports: [port(57500, "Google Chrome")])
    XCTAssertEqual(EventDiff.between(old: before, new: after, at: t), [])
  }

  func testEphemeralPortStillReportedWhenItMatters() {
    let vite = DevServer(framework: "Vite", project: "web")
    let empty = MonitorSnapshot()
    let watched = MonitorSnapshot(ports: [port(60000, "node")])
    XCTAssertEqual(
      EventDiff.between(old: empty, new: watched, at: t, watched: [60000]).map(\.action),
      [.started])
    let dev = MonitorSnapshot(ports: [port(60001, "node", dev: vite)])
    XCTAssertEqual(EventDiff.between(old: empty, new: dev, at: t).map(\.action), [.started])
    // Below the range, nothing changes.
    let low = MonitorSnapshot(ports: [port(9229, "node")])
    XCTAssertEqual(EventDiff.between(old: empty, new: low, at: t).map(\.action), [.started])
  }

  /// The filter skips events, never rows: a row that loses its dev label
  /// between refreshes (a failed `ps`) must not turn into a phantom.
  func testLosingDevLabelIsNotAPhantom() {
    let vite = DevServer(framework: "Vite", project: "web")
    let before = MonitorSnapshot(ports: [port(60001, "node", dev: vite)])
    let after = MonitorSnapshot(ports: [port(60001, "node")])
    XCTAssertEqual(EventDiff.between(old: before, new: after, at: t), [])
  }
}

/// Two processes sharing the log both cross the limit on the same write.
final class PierLogRotationTests: XCTestCase {
  func testSecondRotationKeepsTheFirstOnesHistory() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pier-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("pier.log")
    let previous = dir.appendingPathComponent("pier.log.1")
    try Data("history\n".utf8).write(to: file)

    let first = try FileHandle(forWritingTo: file)
    let second = try FileHandle(forWritingTo: file)
    defer {
      try? first.close()
      try? second.close()
    }
    PierLog.rotate(handle: first, file: file, previous: previous)
    // The other process's next write recreates the log before it rotates.
    try Data("new\n".utf8).write(to: file)
    PierLog.rotate(handle: second, file: file, previous: previous)

    XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "history\n")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new\n")
  }

  func testOrdinaryRotationStillRotates() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pier-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("pier.log")
    let previous = dir.appendingPathComponent("pier.log.1")
    try Data("old\n".utf8).write(to: previous)
    try Data("full\n".utf8).write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    PierLog.rotate(handle: handle, file: file, previous: previous)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "full\n")
  }
}
