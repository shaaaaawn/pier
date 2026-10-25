import Foundation
import XCTest

@testable import Pier

final class DiskSpaceTests: XCTestCase {
  /// Base-10, like Finder and `df -H` — not the binary units RAM uses.
  func testFormatUsesFindersUnits() {
    XCTAssertEqual(DiskSpace.format(88_700_000_000), "89 GB")
    XCTAssertEqual(DiskSpace.format(999_000_000_000), "999 GB")
    XCTAssertEqual(DiskSpace.format(1_250_000_000_000), "1.2 TB")
  }

  /// Finder counts purgeable space as available; the tooltip says so, so Pier
  /// never appears to disagree with it.
  func testTooltipShowsFindersFigureOnlyWhenItDiffers() {
    let withPurgeable = DiskSnapshot(
      free: 88_700_000_000, total: 494_400_000_000, availableIncludingPurgeable: 91_900_000_000)
    XCTAssertTrue(
      MemoryFormat.diskTooltip(withPurgeable).contains("92 GB available incl. purgeable"))
    let same = DiskSnapshot(
      free: 88_700_000_000, total: 494_400_000_000, availableIncludingPurgeable: nil)
    XCTAssertFalse(MemoryFormat.diskTooltip(same).contains("purgeable"))
  }

  /// Whole gigabytes are what's drawn, so sub-GB churn must not republish.
  func testDisplayKeyIgnoresSubGigabyteChurn() {
    let a = DiskSnapshot(
      free: 88_700_000_000, total: 494_400_000_000, availableIncludingPurgeable: nil)
    var b = a
    b.free = 88_900_000_000
    XCTAssertEqual(a.displayKey, b.displayKey)
    b.free = 87_100_000_000
    XCTAssertNotEqual(a.displayKey, b.displayKey)
  }

  func testLiveReadIsPlausible() throws {
    let d = try XCTUnwrap(DiskSpace.read())
    XCTAssertGreaterThan(d.total, 0)
    XCTAssertLessThanOrEqual(d.free, d.total)
  }

  func testFixedMonitorCarriesItsDisk() {
    let disk = DiskSnapshot(free: 1, total: 2, availableIncludingPurgeable: nil)
    let mem = MemorySnapshot(
      total: 1, app: 0, wired: 0, compressed: 0, cached: 0, swapUsed: 0, swapTotal: 0,
      pressure: .normal, swapoutsPerSecond: nil)
    XCTAssertEqual(MemoryMonitor(fixed: mem, disk: disk).disk, disk)
  }
}
