import AppKit
import XCTest

@testable import Pier

/// Icons come from the apps installed on the Mac, by bundle ID; Pier bundles
/// no third-party marks.
final class IconResourceTests: XCTestCase {
  /// Nothing is bundled at all: the menu bar glyph is drawn in code
  /// (`PierGlyph`), and agent icons come from the installed apps.
  func testNoResourcesAreBundled() {
    // #filePath = <package>/Tests/PierTests/IconResourceTests.swift
    let resources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PierTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // <package>
      .appendingPathComponent("Sources/Pier/Resources")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: resources.path),
      "Sources/Pier/Resources is back — Pier bundles no images")
  }

  func testGlyphIsATemplateAtTheRequestedSize() {
    let glyph = PierGlyph.image()
    XCTAssertTrue(glyph.isTemplate)
    XCTAssertEqual(glyph.size, NSSize(width: 16, height: 16))
    XCTAssertEqual(PierGlyph.image(size: 32).size, NSSize(width: 32, height: 32))
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
