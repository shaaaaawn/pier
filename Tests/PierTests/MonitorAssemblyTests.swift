import Foundation
import XCTest

@testable import Pier

/// Assembly used to live inside `refresh()`'s async closure, between five
/// `ProcessRunner` calls — so none of it could be tested without a real
/// machine running real servers. These are the cases that were unreachable.
///
/// All fixture strings are shaped like the real captures already pinned in
/// `LsofParserTests` / `UsageTests`.
final class MonitorAssemblyTests: XCTestCase {
  private let lsof = """
    COMMAND    PID  USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
    node      4100 shawn   23u  IPv4  0x1       0t0  TCP 127.0.0.1:5173 (LISTEN)
    workerd   4200 shawn   19u  IPv4  0x2       0t0  TCP 127.0.0.1:8787 (LISTEN)
    """

  /// pid ppid %cpu rss ucomm — 4100's parent is 3000 (claude), 4200 is orphaned.
  private let psTable = """
    3000     1  0.5  120000 claude
    4100  3000 12.5  340000 node
    4200     1  0.0  210000 workerd
    """

  private let psCommands = """
    3000 shawn /opt/homebrew/bin/claude
    4100 shawn node /Users/shawn/app/vite.js
    4200 shawn workerd serve
    """

  private func probe(cmux: CmuxSnapshot? = nil) -> ProbeOutput {
    ProbeOutput(
      sockets: lsof, processTable: psTable, commandLines: psCommands, cmux: cmux)
  }

  func testAssemblesEntriesFromRawOutput() {
    let result = MonitorAssembly.ports(from: probe())
    XCTAssertEqual(result.entries.map(\.port).sorted(), [5173, 8787])
    XCTAssertEqual(result.commands[4100], "node /Users/shawn/app/vite.js")
  }

  /// The wiring that was previously only exercisable against a live machine:
  /// a port inherits the harness of whatever spawned it, via the process chain.
  func testAttributesAPortToTheHarnessThatSpawnedIt() {
    let result = MonitorAssembly.ports(from: probe())
    let vite = result.entries.first { $0.port == 5173 }
    XCTAssertEqual(vite?.attribution, .harness("Claude Code"))
    // 4200's parent is launchd, so there is genuinely nothing to attribute to.
    // Spelled `Attribution.none` on purpose: against an optional, a bare
    // `.none` binds to `Optional.none` and silently asserts "is nil" instead.
    let worker = result.entries.first { $0.port == 8787 }
    XCTAssertEqual(worker?.attribution, Attribution.none)
  }

  func testAttachesUsageFromTheProcessTable() {
    let result = MonitorAssembly.ports(from: probe())
    let vite = result.entries.first { $0.port == 5173 }
    XCTAssertEqual(vite?.usage?.cpu, 12.5)
    XCTAssertEqual(vite?.usage?.rssKB, 340_000)
  }

  /// Every listed pid gets a reading — including 0 for an idle one, so its
  /// sparkline has a series rather than a gap.
  func testCPUReadingsCoverPortsAndActivity() {
    let result = MonitorAssembly.ports(from: probe())
    let mcp = ActivityEntry(kind: .mcp, name: "node · mcp", detail: "", pids: [3000])
    let readings = MonitorAssembly.cpuReadings(
      entries: result.entries, activity: [mcp], table: result.table)
    XCTAssertEqual(readings[4100], 12.5)
    XCTAssertEqual(readings[4200], 0)  // idle, but present
    XCTAssertEqual(readings[3000], 0.5)  // contributed by the activity row
  }

  /// A pid that holds a port *and* backs an activity row is read once from the
  /// same table, so the two views of it can't disagree.
  func testAPidInBothPortsAndActivityGetsOneConsistentReading() {
    let result = MonitorAssembly.ports(from: probe())
    let sameNode = ActivityEntry(kind: .mcp, name: "node · mcp", detail: "", pids: [4100])
    let readings = MonitorAssembly.cpuReadings(
      entries: result.entries, activity: [sameNode], table: result.table)
    XCTAssertEqual(readings[4100], 12.5)
  }

  /// Assembly must survive every probe failing — a machine with no lsof, or a
  /// timed-out ps, produces empty strings rather than an error.
  func testEmptyProbeYieldsNothingRatherThanCrashing() {
    let result = MonitorAssembly.ports(from: ProbeOutput())
    XCTAssertEqual(result.entries, [])
    XCTAssertEqual(
      MonitorAssembly.cpuReadings(entries: [], activity: [], table: result.table), [:])
  }

  /// cmux is optional. Without it, rows still assemble — they just carry no
  /// surface ref, so the log panel falls back instead of showing nothing.
  func testNoCmuxStillAssemblesRowsWithoutSurfaceRefs() {
    let result = MonitorAssembly.ports(from: probe(cmux: nil))
    XCTAssertEqual(result.entries.count, 2)
    XCTAssertTrue(result.entries.allSatisfy { $0.cmuxSurfaceRef == nil })
  }
}
