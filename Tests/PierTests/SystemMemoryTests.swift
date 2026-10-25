import Foundation
import XCTest

@testable import Pier

final class SystemMemoryTests: XCTestCase {
  private let page: UInt64 = 16_384
  private func gb(_ x: Double) -> UInt64 { UInt64(x * MemoryFormat.gigabyte) }

  private func counters(
    anonymous: UInt64 = 1000, purgeable: UInt64 = 100, wired: UInt64 = 200,
    compressed: UInt64 = 300, external: UInt64 = 50, swapouts: UInt64 = 0
  ) -> VMCounters {
    VMCounters(
      internalPages: anonymous, purgeablePages: purgeable, wiredPages: wired,
      compressedPages: compressed, externalPages: external, swapouts: swapouts)
  }

  // MARK: - Activity Monitor's arithmetic

  /// Memory Used = App (internal − purgeable) + Wired + Compressed — the
  /// definition Activity Monitor uses, so the glance can be checked against it.
  func testUsedFollowsActivityMonitorsDefinition() {
    let s = MemoryMath.snapshot(
      counters: counters(), pageSize: page, total: gb(32), swapUsed: 0, swapTotal: 0,
      pressureLevel: 1, swapoutsPerSecond: nil)
    XCTAssertEqual(s.app, 900 * page)
    XCTAssertEqual(s.wired, 200 * page)
    XCTAssertEqual(s.compressed, 300 * page)
    XCTAssertEqual(s.used, (900 + 200 + 300) * page)
    // Purgeable is counted as cached (droppable), not as used.
    XCTAssertEqual(s.cached, (50 + 100) * page)
  }

  /// The two counts come from one call but aren't guaranteed consistent; an
  /// unclamped subtraction would wrap to ~18 exabytes.
  func testPurgeableAboveInternalClampsInsteadOfWrapping() {
    let s = MemoryMath.snapshot(
      counters: counters(anonymous: 10, purgeable: 50), pageSize: page, total: gb(8),
      swapUsed: 0, swapTotal: 0, pressureLevel: 1, swapoutsPerSecond: nil)
    XCTAssertEqual(s.app, 0)
  }

  // MARK: - Pressure

  func testPressureLevelsMapToActivityMonitorsColours() {
    XCTAssertEqual(MemoryPressure(sysctlLevel: 1), .normal)
    XCTAssertEqual(MemoryPressure(sysctlLevel: 2), .warning)
    XCTAssertEqual(MemoryPressure(sysctlLevel: 4), .critical)
  }

  /// An unknown or unreadable level must not paint the footer red.
  func testUnknownPressureReadsAsNormal() {
    XCTAssertEqual(MemoryPressure(sysctlLevel: 0), .normal)
    XCTAssertEqual(MemoryPressure(sysctlLevel: 3), .normal)
  }

  // MARK: - Paging rate

  func testRateNeedsABaseline() {
    XCTAssertNil(MemoryMath.rate(previous: nil, current: (count: 500, at: 10)))
  }

  func testRateIsDeltaOverTime() {
    XCTAssertEqual(
      MemoryMath.rate(previous: (count: 100, at: 10), current: (count: 700, at: 12)), 300)
    XCTAssertEqual(
      MemoryMath.rate(previous: (count: 100, at: 10), current: (count: 100, at: 12)), 0)
  }

  /// A counter that goes backwards (reset) or no elapsed time must yield nil,
  /// not a huge or infinite rate.
  func testRateRejectsResetsAndZeroIntervals() {
    XCTAssertNil(MemoryMath.rate(previous: (count: 900, at: 10), current: (count: 100, at: 12)))
    XCTAssertNil(MemoryMath.rate(previous: (count: 100, at: 10), current: (count: 200, at: 10)))
  }

  func testPagingOnlyWhenPagesAreActuallyGoingOut() {
    var s = MemoryMath.snapshot(
      counters: counters(), pageSize: page, total: gb(32), swapUsed: gb(4), swapTotal: gb(5),
      pressureLevel: 2, swapoutsPerSecond: 0)
    // Swap that's allocated but idle is not paging.
    XCTAssertFalse(s.isPaging)
    s.swapoutsPerSecond = nil
    XCTAssertFalse(s.isPaging)
    s.swapoutsPerSecond = 12
    XCTAssertTrue(s.isPaging)
  }

  // MARK: - Formatting

  func testGlanceText() {
    let s = MemorySnapshot(
      total: gb(32), app: gb(13), wired: gb(3.1), compressed: gb(11.5), cached: gb(3.7),
      swapUsed: 0, swapTotal: 0, pressure: .normal, swapoutsPerSecond: 0)
    XCTAssertEqual(MemoryFormat.glance(s), "27.6/32 GB · swap 0")
  }

  /// Swap is bytes, never a ratio: the total is 0 until macOS needs swap.
  func testSwapFormatting() {
    XCTAssertEqual(MemoryFormat.swap(0), "0")
    XCTAssertEqual(MemoryFormat.swap(UInt64(512 * MemoryFormat.megabyte)), "512 MB")
    XCTAssertEqual(MemoryFormat.swap(gb(2.3)), "2.3 GB")
  }

  func testTotalReadsAsWholeNumberWhenItIsOne() {
    XCTAssertEqual(MemoryFormat.totalGigabytes(gb(32)), "32")
    XCTAssertEqual(MemoryFormat.totalGigabytes(gb(17.5)), "17.5")
  }

  func testTooltipMentionsPagingOnlyWhenPaging() {
    var s = MemorySnapshot(
      total: gb(32), app: gb(20), wired: gb(5), compressed: gb(6), cached: gb(0.3),
      swapUsed: gb(6.8), swapTotal: gb(8), pressure: .critical, swapoutsPerSecond: 0)
    XCTAssertFalse(MemoryFormat.tooltip(s).contains("Paging"))
    XCTAssertTrue(MemoryFormat.tooltip(s).contains("Memory pressure: Critical"))
    s.swapoutsPerSecond = 340
    XCTAssertTrue(MemoryFormat.tooltip(s).contains("Paging out: 340 pages/s"))
  }

  // MARK: - Publishing

  /// Fluctuations below what the glance draws must not republish — a steady
  /// machine should redraw nothing.
  func testDisplayKeyIgnoresSubDisplayNoise() {
    let a = MemorySnapshot(
      total: gb(32), app: gb(13.01), wired: gb(3.1), compressed: gb(11.5), cached: gb(3.7),
      swapUsed: 0, swapTotal: 0, pressure: .normal, swapoutsPerSecond: 0)
    var b = a
    b.app = gb(13.02)
    XCTAssertEqual(a.displayKey, b.displayKey)
    b.app = gb(13.2)
    XCTAssertNotEqual(a.displayKey, b.displayKey)
    var c = a
    c.pressure = .warning
    XCTAssertNotEqual(a.displayKey, c.displayKey)
  }

  /// Fixture monitors never sample, so renders stay reproducible.
  func testFixedMonitorNeverSamples() {
    let fixed = MemorySnapshot(
      total: gb(32), app: gb(1), wired: gb(1), compressed: gb(1), cached: 0,
      swapUsed: 0, swapTotal: 0, pressure: .normal, swapoutsPerSecond: nil)
    let monitor = MemoryMonitor(fixed: fixed)
    monitor.setActive(true)
    monitor.setActive(false)
    XCTAssertEqual(monitor.snapshot, fixed)
  }

  /// The live path end to end: one real sample produces plausible numbers.
  func testLiveSampleIsPlausible() throws {
    let monitor = MemoryMonitor()
    monitor.sample()
    let s = try XCTUnwrap(monitor.snapshot)
    XCTAssertEqual(s.total, ProcessInfo.processInfo.physicalMemory)
    XCTAssertGreaterThan(s.used, 0)
    XCTAssertLessThanOrEqual(s.used, s.total)
  }
}
