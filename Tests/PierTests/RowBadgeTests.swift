import XCTest

@testable import Pier

/// Rows sit under a collapsible header that already names their attribution,
/// so a row badge should only appear when it says something the header didn't.
final class RowBadgeTests: XCTestCase {
  func testHarnessBadgeDropsUnderItsOwnHeader() {
    let attribution = Attribution.harness("Cursor")
    XCTAssertEqual(attribution.groupTitle, "Cursor")
    XCTAssertNil(attribution.rowBadge(inGroup: "Cursor"))
  }

  func testCmuxKeepsOnlyTheSurface() {
    let attribution = Attribution.cmux(
      workspace: "Idle Screens", surface: "make dev screens", harness: nil)
    XCTAssertEqual(attribution.groupTitle, "cmux · Idle Screens")
    // Header carries the workspace; the row adds which surface it came from.
    XCTAssertEqual(
      attribution.rowBadge(inGroup: "cmux · Idle Screens"), "make dev screens")
  }

  func testCmuxKeepsSurfaceAndDistinctHarness() {
    let attribution = Attribution.cmux(
      workspace: "Personal Agent", surface: "shell", harness: "Kimi")
    XCTAssertEqual(attribution.rowBadge(inGroup: "cmux · Personal Agent"), "shell · Kimi")
  }

  func testCmuxSurfaceEqualToHarnessIsNotRepeated() {
    let attribution = Attribution.cmux(
      workspace: "Personal Agent", surface: "Kimi", harness: "Kimi")
    XCTAssertEqual(attribution.rowBadge(inGroup: "cmux · Personal Agent"), "Kimi")
  }

  func testGenericBucketsDropTheirBadge() {
    XCTAssertNil(Attribution.system.rowBadge(inGroup: "System"))
    XCTAssertNil(Attribution.none.rowBadge(inGroup: "Other"))
  }

  /// Defensive: if a row somehow renders outside its own group, keep the badge
  /// rather than silently losing the attribution.
  func testKeepsBadgeUnderAnUnrelatedHeader() {
    XCTAssertEqual(Attribution.harness("Codex").rowBadge(inGroup: "Cursor"), "Codex")
    XCTAssertEqual(
      Attribution.cmux(workspace: "A", surface: "s", harness: nil)
        .rowBadge(inGroup: "cmux · B"),
      "cmux · A · s")
  }
}
