import XCTest

@testable import Pier

final class UsageTests: XCTestCase {
  // MARK: - Labels

  func testCPULabelCollapsesSubOnePercent() {
    XCTAssertEqual(Usage(cpu: 0, rssKB: 0).cpuLabel, "0%")
    XCTAssertEqual(Usage(cpu: 0.4, rssKB: 0).cpuLabel, "<1%")
    XCTAssertEqual(Usage(cpu: 2.44, rssKB: 0).cpuLabel, "2.4%")
    XCTAssertEqual(Usage(cpu: 94.2, rssKB: 0).cpuLabel, "94%")
    // ps reports per-core, so >100% is legitimate on a multicore box.
    XCTAssertEqual(Usage(cpu: 260, rssKB: 0).cpuLabel, "260%")
  }

  func testMemoryLabelScales() {
    XCTAssertEqual(Usage(cpu: 0, rssKB: 12 * 1024).memoryLabel, "12.0 MB")
    XCTAssertEqual(Usage(cpu: 0, rssKB: 450 * 1024).memoryLabel, "450 MB")
    XCTAssertEqual(Usage(cpu: 0, rssKB: 2048 * 1024).memoryLabel, "2.0 GB")
  }

  // MARK: - History

  func testHistoryAppendsAndCapsAtWindow() {
    var history = UsageHistory()
    for i in 0..<(UsageHistory.window + 10) {
      history.record([7: Double(i)])
    }
    let series = history.series(for: 7)
    XCTAssertEqual(series.count, UsageHistory.window)
    // Oldest samples fall off the front; newest is last.
    XCTAssertEqual(series.last, Double(UsageHistory.window + 9))
  }

  func testHistoryPrunesDeadPids() {
    var history = UsageHistory()
    history.record([1: 5, 2: 6])
    XCTAssertFalse(history.series(for: 2).isEmpty)
    // pid 2 exited — this round only reports pid 1.
    history.record([1: 7])
    XCTAssertTrue(history.series(for: 2).isEmpty, "dead pids must not accumulate")
    XCTAssertEqual(history.series(for: 1), [5, 7])
  }

  // MARK: - Sparkline shaping

  func testHeightsEmptyForNoSamples() {
    XCTAssertTrue(Sparkline.heights([]).isEmpty)
    XCTAssertFalse(Sparkline.isMeaningful([4]))
    XCTAssertTrue(Sparkline.isMeaningful([4, 5]))
  }

  func testHeightsKeepsOnlyTheMostRecentBars() {
    let series = (0..<100).map(Double.init)
    let heights = Sparkline.heights(series, bars: 10)
    XCTAssertEqual(heights.count, 10)
    // Newest sample is the tallest and lands last.
    XCTAssertEqual(heights.last ?? 0, 1.0, accuracy: 0.001)
  }

  func testHeightsNormalizeAgainstSeriesPeak() {
    let heights = Sparkline.heights([25, 50], bars: 2)
    XCTAssertEqual(heights[0], 0.5, accuracy: 0.001)
    XCTAssertEqual(heights[1], 1.0, accuracy: 0.001)
  }

  /// A process idling under the 5% floor must not draw full-height bars —
  /// otherwise "0.2% CPU" looks identical to "pegged".
  func testIdleSeriesStaysNearTheFloor() {
    let heights = Sparkline.heights([0.2, 0.1, 0.3], bars: 3)
    for height in heights {
      XCTAssertLessThan(height, 0.2, "idle CPU should read as a baseline, got \(height)")
      XCTAssertGreaterThanOrEqual(height, Sparkline.minFraction)
    }
  }

  func testHeightsClampToOne() {
    for height in Sparkline.heights([10, 400], bars: 2) {
      XCTAssertLessThanOrEqual(height, 1.0)
    }
  }

  // MARK: - ps parsing

  func testProcessTableParsesUsageColumns() {
    // pid ppid %cpu rss ucomm — ucomm may contain spaces.
    let out = """
        123 1 12.5 204800 node
        456 123 0.0 51200 Google Chrome Helper
      """
    let table = ProcessTable.parse(out)
    XCTAssertEqual(table.byPid[123]?.cpu, 12.5)
    XCTAssertEqual(table.byPid[123]?.rssKB, 204800)
    XCTAssertEqual(table.byPid[123]?.name, "node")
    XCTAssertEqual(table.byPid[456]?.name, "Google Chrome Helper", "name keeps its spaces")
    XCTAssertEqual(table.usage(for: 123), Usage(cpu: 12.5, rssKB: 204800))
    XCTAssertNil(table.usage(for: 999))
  }

  /// The chain-only format (no usage columns) must still parse — attribution
  /// fixtures and older callers pass three fields.
  func testProcessTableStillParsesChainOnlyFormat() {
    let table = ProcessTable.parse("101 50 node\n50 1 claude")
    XCTAssertEqual(table.byPid[101]?.name, "node")
    XCTAssertEqual(table.byPid[101]?.ppid, 50)
    XCTAssertEqual(table.byPid[101]?.cpu, 0)
    XCTAssertEqual(table.chain(from: 101).map(\.name), ["node", "claude"])
  }

  func testUsageSumsAcrossGroupedPids() {
    let table = ProcessTable.parse("1 0 10.0 1024 a\n2 0 5.5 2048 b")
    XCTAssertEqual(table.usage(for: [1, 2]), Usage(cpu: 15.5, rssKB: 3072))
    XCTAssertNil(table.usage(for: [42]))
  }
}
