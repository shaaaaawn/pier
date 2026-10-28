import Carbon.HIToolbox
import ServiceManagement
import XCTest

@testable import Pier

final class SettingsTests: XCTestCase {
  // MARK: - Shortcut

  func testDefaultShortcutAvoidsFindersPathBar() {
    XCTAssertEqual(KeyCombo.defaultCombo.display, "⌃⌥P")
    XCTAssertNotEqual(
      KeyCombo.defaultCombo.modifiers, UInt32(cmdKey | optionKey), "⌥⌘P is Finder's path bar")
  }

  func testDisplayUsesApplesModifierOrder() {
    let combo = KeyCombo(
      keyCode: 0, modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), key: "k")
    XCTAssertEqual(combo.display, "⌃⌥⇧⌘K")
  }

  func testRecordingNeedsARealModifier() {
    XCTAssertNil(
      KeyCombo.from(keyCode: 35, flags: [.shift], characters: "p"), "⇧P is just a capital")
    XCTAssertNil(KeyCombo.from(keyCode: 35, flags: [], characters: "p"))
    XCTAssertEqual(
      KeyCombo.from(keyCode: 35, flags: [.control, .option], characters: "p"),
      KeyCombo.defaultCombo)
  }

  func testStorageRoundTripsAndClearing() {
    let suite = "pier.tests.shortcut"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    XCTAssertEqual(KeyCombo.saved(defaults), .defaultCombo, "unset → default")
    let combo = KeyCombo(keyCode: 40, modifiers: UInt32(cmdKey | controlKey), key: "K")
    KeyCombo.save(combo, defaults)
    XCTAssertEqual(KeyCombo.saved(defaults), combo)
    KeyCombo.save(nil, defaults)
    XCTAssertNil(KeyCombo.saved(defaults), "cleared stays cleared, not back to the default")
  }

  // MARK: - Hidden ports

  func testHiddenPortsParseLeniently() {
    XCTAssertEqual(HiddenPorts.parse("5353, 7000;8080\n 99999 abc 0"), [5353, 7000, 8080])
    XCTAssertEqual(HiddenPorts.format([7000, 5353]), "5353, 7000")
  }

  func testHideAddsToTheSavedSet() {
    let suite = "pier.tests.hidden"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    HiddenPorts.hide(5353, defaults)
    HiddenPorts.hide(7000, defaults)
    HiddenPorts.hide(5353, defaults)
    XCTAssertEqual(HiddenPorts.current(defaults), [5353, 7000])
  }

  // MARK: - Login item

  /// The toggle shows macOS's own status, every state of it.
  func testLoginStatusMapping() {
    XCTAssertEqual(LoginItem.state(.enabled), .on)
    XCTAssertEqual(LoginItem.state(.notRegistered), .off)
    XCTAssertEqual(LoginItem.state(.requiresApproval), .needsApproval)
    XCTAssertEqual(LoginItem.state(.notFound), .unavailable)
  }
}
