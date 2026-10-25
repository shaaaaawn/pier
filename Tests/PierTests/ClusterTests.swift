import XCTest

@testable import Pier

final class ClusterTests: XCTestCase {
  private func e(_ pid: Int32, _ port: Int, attr: Attribution, name: String = "workerd")
    -> PortEntry
  {
    PortEntry(
      pid: pid, port: port, proto: .tcp, processName: name, user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: attr
    )
  }

  private let cmuxAttr = Attribution.cmux(
    workspace: "Acme Web", surface: "make dev web", harness: nil
  )

  /// Five workerd ports on one pid, plus a lone server.
  private var fixture: [PortEntry] {
    [
      e(9122, 60342, attr: cmuxAttr),
      e(9122, 60345, attr: cmuxAttr),
      e(9122, 60350, attr: cmuxAttr),
      e(9122, 60352, attr: cmuxAttr),
      e(9122, 60353, attr: cmuxAttr),
      e(777, 3000, attr: .none, name: "node"),
    ]
  }

  func testSamePidAttributionCollapsesToCluster() {
    let groups = PortMonitor.buildGroups(entries: fixture, matching: "")
    XCTAssertEqual(groups.count, 2)

    let cmuxGroup = groups.first { $0.title == "cmux · Acme Web" }
    XCTAssertEqual(cmuxGroup?.rows.count, 1)
    let cluster = cmuxGroup?.rows[0]
    XCTAssertEqual(cluster?.isCluster, true)
    XCTAssertEqual(cluster?.totalCount, 5)
    XCTAssertEqual(cluster?.entries.map(\.port), [60342, 60345, 60350, 60352, 60353])
    XCTAssertEqual(cluster?.autoExpanded, false)

    let otherGroup = groups.first { $0.title == "Other" }
    XCTAssertEqual(otherGroup?.rows.count, 1)
    XCTAssertEqual(otherGroup?.rows[0].isCluster, false)
  }

  func testSearchFilteringInsideClusterAutoExpands() {
    let groups = PortMonitor.buildGroups(entries: fixture, matching: "60345")
    let cluster = groups.first { $0.title == "cmux · Acme Web" }?.rows[0]
    XCTAssertEqual(cluster?.entries.map(\.port), [60345])
    XCTAssertEqual(cluster?.totalCount, 5)
    XCTAssertEqual(cluster?.autoExpanded, true)
  }

  func testSearchMatchingBadgeKeepsClusterCollapsed() {
    let groups = PortMonitor.buildGroups(entries: fixture, matching: "acme web")
    let cluster = groups.first { $0.title == "cmux · Acme Web" }?.rows[0]
    XCTAssertEqual(cluster?.totalCount, 5)
    XCTAssertEqual(cluster?.entries.count, 5)
    XCTAssertEqual(cluster?.autoExpanded, false)
  }

  func testDifferentAttributionSamePidDoesNotCluster() {
    let entries = [
      e(100, 8000, attr: cmuxAttr),
      e(100, 8001, attr: .none),
    ]
    let rows = PortMonitor.buildGroups(entries: entries, matching: "")
      .flatMap(\.rows)
    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(rows.allSatisfy { !$0.isCluster })
  }

  func testGroupEntryCountCountsVisibleChildren() {
    let groups = PortMonitor.buildGroups(entries: fixture, matching: "")
    XCTAssertEqual(groups.first { $0.title == "cmux · Acme Web" }?.entryCount, 5)
  }
}

final class SmartBadgeLabelTests: XCTestCase {
  func testShortLabelsPassThrough() {
    XCTAssertEqual(Attribution.harness("Kimi").smartBadgeLabel(), "Kimi")
    XCTAssertEqual(
      Attribution.cmux(workspace: "W", surface: "Kimi", harness: "Kimi").smartBadgeLabel(),
      "cmux · W · Kimi"
    )
  }

  func testMiddleSegmentsDroppedBeforeSurface() {
    let attr = Attribution.cmux(workspace: "Backend", surface: "server", harness: "Kimi")
    // full = "cmux · Backend · server · Kimi" (30 chars); mid-drop = 25 chars
    XCTAssertEqual(attr.smartBadgeLabel(maxChars: 25), "cmux · Backend · … · Kimi")
    XCTAssertEqual(attr.smartBadgeLabel(maxChars: 24), "cmux · Backend · …")
  }

  func testSurfaceDroppedBeforeWorkspace() {
    let attr = Attribution.cmux(
      workspace: "Acme Web", surface: "make dev web", harness: nil)
    let label = attr.smartBadgeLabel(maxChars: 24)
    XCTAssertEqual(label, "cmux · Acme Web · …")
    XCTAssertLessThanOrEqual(label.count, 24)
  }

  func testHugeWorkspaceFallsBackToTruncation() {
    let attr = Attribution.cmux(
      workspace: "A Workspace Name Far Too Long To Ever Fit", surface: "s", harness: nil
    )
    let label = attr.smartBadgeLabel(maxChars: 24)
    XCTAssertLessThanOrEqual(label.count, 24)
    XCTAssertTrue(label.hasSuffix("…"))
  }

  func testFullLabelStillAvailable() {
    let attr = Attribution.cmux(
      workspace: "Acme Web", surface: "make dev web", harness: nil)
    XCTAssertEqual(attr.badgeLabel, "cmux · Acme Web · make dev web")
  }
}
