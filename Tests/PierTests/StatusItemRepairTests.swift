import AppKit
import XCTest

@testable import Pier

/// Four different faults produce the identical symptom — "Pier is running but
/// there's no menu bar icon". These cover the three that are repairable or
/// detectable from inside the app.
final class StatusItemRepairTests: XCTestCase {
  /// `name` alone collides with XCTestCase's own `name` property.
  private let itemName = StatusItemRepair.autosaveName

  private func freshDefaults(_ function: String = #function) -> UserDefaults {
    let suite = "pier.tests.\(function)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
  }

  // MARK: - Stale "hidden" flag

  func testClearsOurOwnFalseVisibilityFlag() {
    XCTAssertTrue(
      StatusItemRepair.shouldClearVisibility(
        key: StatusItemRepair.visibilityKey(itemName), value: false, autosaveName: itemName))
  }

  /// The keys macOS wrote before Pier adopted an autosave name are ours too.
  func testClearsLegacyItemNKeys() {
    XCTAssertTrue(
      StatusItemRepair.shouldClearVisibility(
        key: "NSStatusItem VisibleCC Item-0", value: false, autosaveName: itemName))
    XCTAssertTrue(
      StatusItemRepair.shouldClearVisibility(
        key: "NSStatusItem VisibleCC Item-12", value: false, autosaveName: itemName))
  }

  /// Never touch another app's entry, and never "repair" a *true* flag.
  func testLeavesOtherAppsAndVisibleItemsAlone() {
    XCTAssertFalse(
      StatusItemRepair.shouldClearVisibility(
        key: "NSStatusItem VisibleCC com.other.app", value: false, autosaveName: itemName))
    XCTAssertFalse(
      StatusItemRepair.shouldClearVisibility(
        key: StatusItemRepair.visibilityKey(itemName), value: true, autosaveName: itemName))
    XCTAssertFalse(
      StatusItemRepair.shouldClearVisibility(
        key: "SomeUnrelatedKey", value: false, autosaveName: itemName))
  }

  func testLegacyNameMatching() {
    XCTAssertTrue(StatusItemRepair.isLegacyItemName("Item-0"))
    XCTAssertTrue(StatusItemRepair.isLegacyItemName("Item-12"))
    XCTAssertFalse(StatusItemRepair.isLegacyItemName("Item-"))
    XCTAssertFalse(StatusItemRepair.isLegacyItemName("Item-abc"))
    XCTAssertFalse(StatusItemRepair.isLegacyItemName("pier-status-item"))
  }

  /// The visibility sweep runs **once**. Repeating it would undo a user who
  /// later hides the item on purpose.
  func testVisibilitySweepRunsOnlyOnce() {
    let defaults = freshDefaults()
    defaults.set(false, forKey: StatusItemRepair.visibilityKey(itemName))
    let first = StatusItemRepair.repairDefaults(defaults, autosaveName: itemName, maxScreenX: 3000)
    XCTAssertEqual(first, [StatusItemRepair.visibilityKey(itemName)])

    // The user hides it deliberately afterwards — that must survive.
    defaults.set(false, forKey: StatusItemRepair.visibilityKey(itemName))
    let second = StatusItemRepair.repairDefaults(defaults, autosaveName: itemName, maxScreenX: 3000)
    XCTAssertEqual(second, [])
    XCTAssertEqual(
      defaults.object(forKey: StatusItemRepair.visibilityKey(itemName)) as? Bool, false)
  }

  // MARK: - Corrupt saved position

  func testClearsNonPositivePositions() {
    XCTAssertTrue(StatusItemRepair.shouldClearPosition(NSNumber(value: 0), maxScreenX: 3000))
    XCTAssertTrue(StatusItemRepair.shouldClearPosition(NSNumber(value: -40), maxScreenX: 3000))
  }

  func testClearsPositionsFarBeyondEveryScreen() {
    XCTAssertTrue(StatusItemRepair.shouldClearPosition(NSNumber(value: 9000), maxScreenX: 3000))
  }

  /// A display unplugged a moment ago legitimately leaves a position slightly
  /// past the current widest screen — that must not be wiped.
  func testKeepsPositionsWithinSlackOfTheWidestScreen() {
    XCTAssertFalse(StatusItemRepair.shouldClearPosition(NSNumber(value: 3200), maxScreenX: 3000))
    XCTAssertFalse(StatusItemRepair.shouldClearPosition(NSNumber(value: 1200), maxScreenX: 3000))
  }

  func testKeepsPositionsWhenNoScreenInfoIsAvailable() {
    XCTAssertFalse(StatusItemRepair.shouldClearPosition(NSNumber(value: 99_000), maxScreenX: nil))
  }

  func testRepairsPositionEveryLaunchNotJustOnce() {
    let defaults = freshDefaults()
    let key = StatusItemRepair.positionKey(itemName)
    defaults.set(-5, forKey: key)
    XCTAssertEqual(
      StatusItemRepair.repairDefaults(defaults, autosaveName: itemName, maxScreenX: 3000).first, key
    )
    // A second corruption, after the one-shot visibility sweep is spent.
    defaults.set(-5, forKey: key)
    XCTAssertEqual(
      StatusItemRepair.repairDefaults(defaults, autosaveName: itemName, maxScreenX: 3000), [key])
  }

  func testRepairsLegacyItemNPositionsToo() {
    let defaults = freshDefaults()
    defaults.set(-1, forKey: StatusItemRepair.positionKey("Item-3"))
    let cleared = StatusItemRepair.repairDefaults(
      defaults, autosaveName: itemName, maxScreenX: 3000)
    XCTAssertTrue(cleared.contains(StatusItemRepair.positionKey("Item-3")))
  }

  // MARK: - System force-hiding

  /// `isVisible == false` is the user hiding it on purpose — not a fault.
  func testIntentionallyHiddenItemIsNotFlagged() {
    let snapshot = StatusItemRepair.Snapshot(
      isVisible: false, hasButton: true, hasWindow: false, hasScreen: false, buttonWidth: 0)
    XCTAssertFalse(StatusItemRepair.isSystemHidden(snapshot))
  }

  /// Visible, has a button, but the system took its window away.
  func testVisibleItemWithoutAWindowIsFlagged() {
    let snapshot = StatusItemRepair.Snapshot(
      isVisible: true, hasButton: true, hasWindow: false, hasScreen: false, buttonWidth: 18)
    XCTAssertTrue(StatusItemRepair.isSystemHidden(snapshot))
  }

  /// Regression: a healthy item reports no screen whenever its menu bar isn't
  /// being drawn — the normal state for an item on a display running a
  /// fullscreen Split View space. Treating that as hidden flagged a visible
  /// icon on this machine, verified against the live app.
  func testWindowWithoutAScreenIsNotFlagged() {
    let snapshot = StatusItemRepair.Snapshot(
      isVisible: true, hasButton: true, hasWindow: true, hasScreen: false, buttonWidth: 49)
    XCTAssertFalse(StatusItemRepair.isSystemHidden(snapshot))
  }

  func testHealthyItemIsNotFlagged() {
    let snapshot = StatusItemRepair.Snapshot(
      isVisible: true, hasButton: true, hasWindow: true, hasScreen: true, buttonWidth: 42)
    XCTAssertFalse(StatusItemRepair.isSystemHidden(snapshot))
  }

  /// The snapshot doubles as the log line, so its format is part of the contract.
  func testSnapshotDescriptionIsOneDenseLine() {
    let snapshot = StatusItemRepair.Snapshot(
      isVisible: true, hasButton: true, hasWindow: false, hasScreen: false, buttonWidth: 18)
    XCTAssertEqual(
      snapshot.description,
      "visible=true,button=true,window=false,screen=false,width=18.0")
  }
}
