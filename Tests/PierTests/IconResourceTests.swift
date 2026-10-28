import XCTest

@testable import Pier

/// Icons come from the apps installed on the Mac, by bundle ID; Pier bundles
/// no third-party marks.
final class IconResourceTests: XCTestCase {
  func testNoThirdPartyIconsAreBundled() {
    // #filePath = <package>/Tests/PierTests/IconResourceTests.swift
    let resources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PierTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // <package>
      .appendingPathComponent("Sources/Pier/Resources")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
    XCTAssertEqual(
      Set(files.filter { !$0.hasPrefix(".") }),
      ["menubar-icon.png", "menubar-icon@2x.png", "menubar-icon@3x.png"],
      "Resources holds Pier's own icon only")
  }

  func testBundleIDsLookLikeBundleIDs() {
    for rule in harnessTable {
      for id in rule.apps {
        XCTAssertGreaterThanOrEqual(id.split(separator: ".").count, 2, "\(rule.label): \(id)")
        XCTAssertFalse(id.contains(" "), "\(rule.label): \(id)")
      }
    }
  }

  func testAttributionExposesIconApps() {
    XCTAssertEqual(Attribution.harness("Codex").iconApps, ["com.openai.codex"])
    XCTAssertEqual(
      Attribution.cmux(workspace: "W", surface: "S", harness: "Claude Code").iconApps,
      ["com.anthropic.claudefordesktop"])
    XCTAssertEqual(
      Attribution.terminal(TerminalSession(app: .ghostty, directory: "~", tty: "ttys001")).iconApps,
      ["com.mitchellh.ghostty"])
    XCTAssertEqual(Attribution.harness("Aider").iconApps, [])
    XCTAssertEqual(Attribution.cmux(workspace: "W", surface: "S", harness: nil).iconApps, [])
    XCTAssertEqual(Attribution.system.iconApps, [])
    XCTAssertEqual(Attribution.none.iconApps, [])
  }

  @MainActor
  func testLookupMissesAndDisabledLookupsReturnNil() {
    XCTAssertNil(AppIcons.image(for: ["invalid.pier.no-such-app"]))
    XCTAssertNil(AppIcons.image(for: []))
    AppIcons.lookupEnabled = false
    defer { AppIcons.lookupEnabled = true }
    XCTAssertNil(AppIcons.image(for: ["com.apple.Terminal"]))
  }
}
