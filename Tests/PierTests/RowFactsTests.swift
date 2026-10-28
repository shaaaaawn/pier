import XCTest

@testable import Pier

/// The facts the redesigned rows show: age, network exposure, detached.
final class RowFactsTests: XCTestCase {
  func entry(binds: [String] = ["127.0.0.1"], start: UInt64? = nil) -> PortEntry {
    var e = PortEntry(
      pid: 4242, port: 3000, proto: .tcp, processName: "node", user: "dev",
      bindAddresses: binds, attribution: .none)
    e.startTime = start
    return e
  }

  func testAgeIsCompact() {
    XCTAssertEqual(PortEntry.ageText(seconds: 12), "<1m")
    XCTAssertEqual(PortEntry.ageText(seconds: 4 * 60 + 5), "4m")
    XCTAssertEqual(PortEntry.ageText(seconds: 2 * 3600 + 59), "2h")
    XCTAssertEqual(PortEntry.ageText(seconds: 3 * 86_400), "3d")
    XCTAssertEqual(PortEntry.ageText(seconds: -5), "<1m", "clock skew isn't negative age")
    // From a libproc start time (µs since the epoch).
    let now = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(entry(start: UInt64(1_000_000 - 7200) * 1_000_000).age(now: now), "2h")
    XCTAssertNil(entry().age(now: now), "fixtures have no start time")
  }

  func testLANMeansEveryInterface() {
    XCTAssertTrue(entry(binds: ["*"]).isOnLAN)
    XCTAssertTrue(entry(binds: ["::", "127.0.0.1"]).isOnLAN)
    XCTAssertFalse(entry(binds: ["127.0.0.1", "::1"]).isOnLAN)
    XCTAssertFalse(entry(binds: ["192.168.1.20"]).isOnLAN, "one interface isn't every interface")
  }

  // MARK: - Detached

  func chain(_ rows: String, from pid: Int32) -> [ProcessTable.Proc] {
    ProcessTable.parse(rows).chain(from: pid)
  }

  /// An agent ran `npm run dev &` and exited: node is re-parented to launchd.
  func testOrphanedDevServerIsDetached() {
    let c = chain("300 1 0 1 node\n301 300 0 1 node", from: 301)
    XCTAssertTrue(DevServers.isDetached(chain: c, attribution: .none))
  }

  func testAnythingMindingItIsNotDetached() {
    // Still in a shell (a terminal tab, `make up`'s supervisor…).
    XCTAssertFalse(
      DevServers.isDetached(
        chain: chain("200 1 0 1 zsh\n300 200 0 1 node", from: 300), attribution: .none))
    // A process manager restarts it on purpose.
    XCTAssertFalse(
      DevServers.isDetached(
        chain: chain("200 1 0 1 PM2\n300 200 0 1 node", from: 300), attribution: .none))
    // Attributed to an agent or terminal: someone's there.
    XCTAssertFalse(
      DevServers.isDetached(
        chain: chain("300 1 0 1 node", from: 300), attribution: .harness("Claude Code")))
  }

  func testStopAllConfirmationListsEachServer() {
    var a = entry()
    a.dev = DevServer(framework: "Next.js", project: "old-landing")
    let summary = PortListView.detachedSummary([a])
    XCTAssertTrue(summary.contains(":3000  Next.js · old-landing  (pid 4242)"))
    XCTAssertTrue(summary.contains("checking it's still the same process"))
  }

  func testLANAddressIsAnIPv4OrNothing() {
    if let ip = LAN.ipv4() {
      XCTAssertEqual(ip.split(separator: ".").count, 4)
      XCTAssertFalse(ip.hasPrefix("127."))
    }
  }
}
