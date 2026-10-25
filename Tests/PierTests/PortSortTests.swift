import Foundation
import XCTest

@testable import Pier

final class PortSortTests: XCTestCase {
  private func entry(
    _ port: Int, _ name: String, pid: Int32 = 1, actor: Attribution = .none,
    cpu: Double = 0, bind: String = "127.0.0.1"
  ) -> PortEntry {
    PortEntry(
      pid: pid, port: port, proto: .tcp, processName: name, user: "dev",
      bindAddresses: [bind], attribution: actor, usage: Usage(cpu: cpu, rssKB: 0))
  }

  private func history(_ samples: [Int32: [Double]]) -> UsageHistory {
    var h = UsageHistory()
    // record() drops pids missing from the reading, so replay sample-by-sample.
    let depth = samples.values.map(\.count).max() ?? 0
    for i in 0..<depth {
      var round: [Int32: Double] = [:]
      for (pid, series) in samples where i < series.count { round[pid] = series[i] }
      h.record(round)
    }
    return h
  }

  // MARK: - Web-server heuristic

  func testDevPortsCountAsWebServers() {
    XCTAssertTrue(ActivityRank.isLikelyWebServer(entry(5173, "node")))
    XCTAssertTrue(ActivityRank.isLikelyWebServer(entry(8787, "workerd")))
    XCTAssertTrue(ActivityRank.isLikelyWebServer(entry(3000, "someRandomBinary")))
  }

  func testWebProcessOnAnUnusualPortStillCounts() {
    XCTAssertTrue(ActivityRank.isLikelyWebServer(entry(51733, "node")))
    XCTAssertTrue(ActivityRank.isLikelyWebServer(entry(59754, "python3.11")))
  }

  /// A loopback IPC socket is bindable but is not what you opened Pier to find.
  func testRandomLoopbackSocketIsNotAWebServer() {
    XCTAssertFalse(ActivityRank.isLikelyWebServer(entry(51731, "Cursor Helper (Plugin)")))
    XCTAssertFalse(ActivityRank.isLikelyWebServer(entry(63342, "rapportd")))
  }

  // MARK: - Ordering

  /// The headline case: a dev server idling at 0% right now must still outrank
  /// a busy background daemon. Instantaneous CPU alone gets this backwards.
  func testIdleWebServerOutranksBusyDaemon() {
    let vite = entry(5173, "node", pid: 1, actor: .harness("Claude Code"), cpu: 0)
    let daemon = entry(51900, "logioptionsplus_agent", pid: 2, cpu: 22)
    let h = history([1: [0, 0, 0], 2: [22, 24, 21]])
    XCTAssertTrue(ActivityRank.areInOrder(vite, daemon, sort: .activity, history: h))
  }

  /// Recent peak beats the current sample: a server that compiled 30s ago and
  /// is idle now is more interesting than one that has never done anything.
  func testRecentPeakCountsNotJustTheCurrentSample() {
    let busy = entry(5173, "node", pid: 1, cpu: 0)
    let quiet = entry(5174, "node", pid: 2, cpu: 0)
    let h = history([1: [0, 90, 40, 0], 2: [0, 0, 0, 0]])
    XCTAssertTrue(ActivityRank.areInOrder(busy, quiet, sort: .activity, history: h))
  }

  /// System daemons stay down the list however busy they get — httpd on :80 is
  /// never the answer to "what am I running?".
  func testSystemPortsSinkEvenWhenTheyLookWebby() {
    let system = entry(80, "httpd", pid: 1, actor: .system, cpu: 50)
    let mine = entry(4321, "node", pid: 2, cpu: 0)
    let h = history([1: [50, 50], 2: [0, 0]])
    XCTAssertTrue(ActivityRank.areInOrder(mine, system, sort: .activity, history: h))
  }

  /// A server runtime outranks a stranger squatting a conventional port.
  func testWebProcessNameOutranksDevPortAlone() {
    let real = entry(51733, "node", pid: 1)
    let squatter = entry(5000, "SomeDaemon", pid: 2)
    let h = history([1: [0], 2: [0]])
    XCTAssertTrue(ActivityRank.areInOrder(real, squatter, sort: .activity, history: h))
    XCTAssertTrue(ActivityRank.isLikelyWebServer(squatter))
    XCTAssertFalse(ActivityRank.hasWebProcessName(squatter))
  }

  func testAgentAttributedBeatsUnattributed() {
    let agent = entry(9101, "node", pid: 1, actor: .harness("Claude Code"))
    let plain = entry(9102, "node", pid: 2)
    let h = history([1: [0], 2: [0]])
    XCTAssertTrue(ActivityRank.areInOrder(agent, plain, sort: .activity, history: h))
  }

  func testPortAndNameModes() {
    let a = entry(8080, "zebra", pid: 1)
    let b = entry(3000, "alpha", pid: 2)
    let h = UsageHistory()
    XCTAssertTrue(ActivityRank.areInOrder(b, a, sort: .port, history: h))
    XCTAssertTrue(ActivityRank.areInOrder(b, a, sort: .name, history: h))
    XCTAssertFalse(ActivityRank.areInOrder(a, b, sort: .name, history: h))
  }

  /// Every mode must be a *total* order. A comparator that returns false both
  /// ways lets the list reshuffle on each 5s refresh, which looks like a bug.
  func testOrderingIsTotalForIdenticalScores() {
    let a = entry(3000, "node", pid: 1)
    let b = entry(3000, "node", pid: 2)
    let h = UsageHistory()
    for mode in PortSort.allCases {
      let forward = ActivityRank.areInOrder(a, b, sort: mode, history: h)
      let backward = ActivityRank.areInOrder(b, a, sort: mode, history: h)
      XCTAssertNotEqual(forward, backward, "\(mode.label) is not a strict ordering")
    }
  }

  // MARK: - Group level

  /// Activity mode floats the section holding the liveliest listener; System
  /// stays pinned last regardless.
  func testActivityModeFloatsTheLiveliestGroupButKeepsSystemLast() {
    let entries = [
      entry(51000, "somebinary", pid: 1, actor: .harness("Cursor")),
      entry(5173, "node", pid: 2, actor: .harness("Claude Code"), cpu: 40),
      entry(80, "httpd", pid: 3, actor: .system, cpu: 90),
    ]
    let h = history([1: [0, 0], 2: [40, 44], 3: [90, 92]])
    let groups = PortMonitor.buildGroups(
      entries: entries, matching: "", sort: .activity, history: h)
    XCTAssertEqual(groups.first?.title, "Claude Code")
    XCTAssertEqual(groups.last?.title, "System")
  }

  func testPortModeKeepsTheSemanticGroupOrder() {
    let entries = [
      entry(51000, "somebinary", pid: 1, actor: .harness("Cursor")),
      entry(5173, "node", pid: 2, actor: .harness("Claude Code"), cpu: 40),
    ]
    let byPort = PortMonitor.buildGroups(entries: entries, matching: "", sort: .port)
    XCTAssertEqual(byPort.map(\.title), ["Claude Code", "Cursor"].sorted())
  }
}
