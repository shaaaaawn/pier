@testable import Pier
import XCTest

/// Every icon referenced by the harness table must exist as a 32px PNG in
/// Sources/Pier/Resources/icons/ (run scripts/convert-icons.sh after adding
/// a new harness icon).
final class IconResourceTests: XCTestCase {
  private var iconsDir: URL {
    // #filePath = <package>/Tests/PierTests/IconResourceTests.swift
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // PierTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // <package>
      .appendingPathComponent("Sources/Pier/Resources/icons")
  }

  func testEveryHarnessIconExists() {
    let referenced = harnessTable.compactMap(\.icon)
    XCTAssertFalse(referenced.isEmpty, "harness table should reference at least one icon")
    for name in referenced {
      let path = iconsDir.appendingPathComponent("\(name).png").path
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: path),
        "missing icon resource: Sources/Pier/Resources/icons/\(name).png"
      )
    }
  }

  func testIconNamesRoundTripThroughLabels() {
    for rule in harnessTable where rule.icon != nil {
      XCTAssertEqual(Attributor.iconName(forHarnessLabel: rule.label), rule.icon)
    }
  }

  func testAttributionExposesIconName() {
    XCTAssertEqual(Attribution.harness("Kimi").iconName, "kimi-code")
    XCTAssertEqual(
      Attribution.cmux(workspace: "W", surface: "S", harness: "Claude Code").iconName,
      "claude-code"
    )
    XCTAssertNil(Attribution.cmux(workspace: "W", surface: "S", harness: nil).iconName)
    XCTAssertNil(Attribution.harness("tmux").iconName)
    XCTAssertNil(Attribution.system.iconName)
    XCTAssertNil(Attribution.none.iconName)
  }
}
