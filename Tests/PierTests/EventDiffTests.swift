import Foundation
import XCTest

@testable import Pier

final class EventDiffTests: XCTestCase {
  private let t = Date(timeIntervalSince1970: 1_000)

  private func port(_ port: Int, _ name: String, pid: Int32 = 100, actor: Attribution = .none)
    -> PortEntry
  {
    PortEntry(
      pid: pid, port: port, proto: .tcp, processName: name, user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: actor)
  }

  private func container(_ name: String, running: Bool, kind: ActivityKind = .docker)
    -> ActivityEntry
  {
    ActivityEntry(kind: kind, name: name, detail: "", isRunning: running)
  }

  private func mcp(_ name: String, pids: [Int32], actor: Attribution = .harness("Claude Code"))
    -> ActivityEntry
  {
    ActivityEntry(kind: .mcp, name: name, detail: "", pids: pids, attribution: actor)
  }

  /// The single most important case: launching Pier must not announce the ~37
  /// things that were already running before it started.
  func testColdStartEmitsNothing() {
    let snapshot = MonitorSnapshot(
      ports: [port(3000, "node"), port(8080, "workerd")],
      activity: [container("data_redis", running: true), mcp("node · mcp", pids: [1, 2])])
    XCTAssertEqual(EventDiff.between(old: nil, new: snapshot, at: t), [])
  }

  func testNoChangeEmitsNothing() {
    let snapshot = MonitorSnapshot(
      ports: [port(3000, "node")], activity: [container("data_redis", running: true)])
    XCTAssertEqual(EventDiff.between(old: snapshot, new: snapshot, at: t), [])
  }

  func testPortAppearingAndVanishing() {
    let before = MonitorSnapshot(ports: [port(3000, "node")])
    let after = MonitorSnapshot(ports: [port(8080, "workerd", actor: .harness("Claude Code"))])
    let events = EventDiff.between(old: before, new: after, at: t)
    XCTAssertEqual(events.count, 2)
    let started = events.first { $0.action == .started }
    XCTAssertEqual(started?.subject, .port(8080, process: "workerd"))
    XCTAssertEqual(started?.summary, "Claude Code started workerd on :8080")
    let stopped = events.first { $0.action == .stopped }
    XCTAssertEqual(stopped?.subject, .port(3000, process: "node"))
  }

  /// Both engines list stopped containers now, so a stop is an `isRunning` flip
  /// with the row still present. Diffing on presence alone would miss it.
  func testContainerStopIsAStateFlipNotADisappearance() {
    let before = MonitorSnapshot(activity: [container("data_redis", running: true)])
    let after = MonitorSnapshot(activity: [container("data_redis", running: false)])
    let events = EventDiff.between(old: before, new: after, at: t)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.action, .stopped)
    XCTAssertEqual(events.first?.subject, .container(.docker, "data_redis"))
  }

  func testContainerStartIsAStateFlip() {
    let before = MonitorSnapshot(activity: [container("data_redis", running: false)])
    let after = MonitorSnapshot(activity: [container("data_redis", running: true)])
    XCTAssertEqual(EventDiff.between(old: before, new: after, at: t).first?.action, .started)
  }

  /// `docker rm` on a container that was already stopped is housekeeping — it
  /// didn't kill anything, so it must not read as a kill.
  func testRemovingAStoppedContainerIsNotAnEvent() {
    let before = MonitorSnapshot(activity: [container("scratch", running: false)])
    XCTAssertEqual(EventDiff.between(old: before, new: MonitorSnapshot(), at: t), [])
  }

  func testRemovingARunningContainerCountsAsStopped() {
    let before = MonitorSnapshot(activity: [container("web", running: true)])
    let events = EventDiff.between(old: before, new: MonitorSnapshot(), at: t)
    XCTAssertEqual(events.map(\.action), [.stopped])
  }

  /// A container that exists but was created stopped never ran, so it's not a
  /// start.
  func testNewlyCreatedStoppedContainerIsNotAStart() {
    let events = EventDiff.between(
      old: MonitorSnapshot(), new: MonitorSnapshot(activity: [container("new", running: false)]),
      at: t)
    XCTAssertEqual(events, [])
  }

  /// The headline case: an agent kills some of its MCP servers. The row stays,
  /// the count drops.
  func testPartialMCPKillReportsTheDelta() {
    let before = MonitorSnapshot(activity: [
      mcp("node · chrome-devtools-mcp", pids: [1, 2, 3, 4, 5])
    ])
    let after = MonitorSnapshot(activity: [mcp("node · chrome-devtools-mcp", pids: [1, 2])])
    let events = EventDiff.between(old: before, new: after, at: t)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.action, .stopped)
    XCTAssertEqual(events.first?.count, 3)
    XCTAssertEqual(
      events.first?.summary, "Claude Code stopped node · chrome-devtools-mcp ×3")
  }

  func testWholeMCPRowVanishing() {
    let before = MonitorSnapshot(activity: [mcp("uv · blender-mcp", pids: [7])])
    let events = EventDiff.between(old: before, new: MonitorSnapshot(), at: t)
    XCTAssertEqual(events.map(\.action), [.stopped])
    XCTAssertEqual(events.first?.count, 1)
  }

  /// The same server under two harnesses is two rows; one exiting must not read
  /// as a count change on the other.
  func testSameLabelUnderDifferentHarnessesAreDistinct() {
    let before = MonitorSnapshot(
      activity: [
        mcp("node · mcp", pids: [1, 2], actor: .harness("Claude Code")),
        mcp("node · mcp", pids: [3], actor: .harness("Cursor")),
      ])
    let after = MonitorSnapshot(
      activity: [mcp("node · mcp", pids: [1, 2], actor: .harness("Claude Code"))])
    let events = EventDiff.between(old: before, new: after, at: t)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.summary, "Cursor stopped node · mcp")
  }

  func testSelfInitiatedEventReadsAsYou() {
    var event = PierEvent(
      date: t, action: .stopped, subject: .container(.docker, "data_redis"),
      actor: .none)
    XCTAssertEqual(event.summary, "local stopped data_redis")
    event.selfInitiated = true
    XCTAssertEqual(event.summary, "you stopped data_redis")
  }
}
