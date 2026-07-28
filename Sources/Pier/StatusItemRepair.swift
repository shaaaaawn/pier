import AppKit
import Foundation

/// Defends against the status item silently not appearing.
///
/// Four separate causes produce the identical symptom — "Pier is running but
/// there's no icon" — and they need different fixes. App Nap dropping the item
/// is handled in `AppDelegate` (`beginActivity`). The other three live here,
/// ported from CodexBar, which hit all of them in the field:
///
/// 1. `NSStatusItem VisibleCC <name> = false` persists in `UserDefaults`. Once
///    written, the item never appears again, across relaunches and rebuilds.
/// 2. `NSStatusItem Preferred Position <name>` persists an x-coordinate. If it
///    is `<= 0` or further right than any screen, the item is placed off-screen.
/// 3. macOS 26 can force-hide an item entirely. That isn't repairable — but it
///    is *detectable*, and "the system hid it" is a different message from
///    "something is broken".
///
/// Every decision here is a pure function over defaults values or a snapshot,
/// so it's testable without a window server — the same reason Pier's CLI
/// parsers take captured output rather than shelling out.
enum StatusItemRepair {
  /// A stable autosave name is a prerequisite, not a nicety: with none, macOS
  /// keys this state by launch-order index (`Item-0`, `Item-1`, …), which moves
  /// between runs — so the position isn't reliably restored and there's no
  /// stable key to repair. Changing it repositions the item once.
  static let autosaveName = "pier-status-item"

  static let visibilityPrefix = "NSStatusItem VisibleCC "
  static let positionPrefix = "NSStatusItem Preferred Position "
  /// A saved position may legitimately exceed the current widest screen when a
  /// display was just unplugged, so only treat it as corrupt well beyond that.
  static let positionSlack: Double = 512
  /// Set once a repair sweep has run, so a *deliberate* later hide by the user
  /// is respected instead of being undone on every launch.
  static let didRepairKey = "hasRepairedStatusItemDefaults"

  static func visibilityKey(_ name: String) -> String { visibilityPrefix + name }
  static func positionKey(_ name: String) -> String { positionPrefix + name }

  // MARK: - 1. Stale "hidden" flag

  /// Only a *false* visibility flag is a fault, and only for keys we own: our
  /// own autosave name, or the `Item-N` keys macOS wrote before Pier adopted
  /// one. Never touch another app's entry.
  static func shouldClearVisibility(key: String, value: Any?, autosaveName: String) -> Bool {
    guard key.hasPrefix(visibilityPrefix), boolValue(value) == false else { return false }
    let item = String(key.dropFirst(visibilityPrefix.count))
    return item == autosaveName || isLegacyItemName(item)
  }

  /// `Item-0`, `Item-12` — the names macOS assigns when no autosave name is set.
  static func isLegacyItemName(_ name: String) -> Bool {
    guard name.hasPrefix("Item-") else { return false }
    let digits = name.dropFirst("Item-".count)
    return !digits.isEmpty && digits.allSatisfy(\.isNumber)
  }

  // MARK: - 2. Corrupt saved position

  static func shouldClearPosition(_ value: Any?, maxScreenX: Double?) -> Bool {
    guard let number = value as? NSNumber else { return value != nil }
    let position = number.doubleValue
    if position <= 0 { return true }
    guard let maxScreenX else { return false }
    return position > maxScreenX + positionSlack
  }

  // MARK: - 3. System force-hiding (detect only)

  /// What the item itself reports. One dense line doubles as the assertion
  /// value and the diagnostic string.
  struct Snapshot: Equatable, CustomStringConvertible {
    var isVisible: Bool
    var hasButton: Bool
    var hasWindow: Bool
    var hasScreen: Bool
    var buttonWidth: CGFloat

    var description: String {
      "visible=\(isVisible),button=\(hasButton),window=\(hasWindow),"
        + "screen=\(hasScreen),width=\(String(format: "%.1f", Double(buttonWidth)))"
    }
  }

  /// An item we asked to be visible, that has a button but **no window**, has
  /// been taken away by the system. `isVisible == false` is not a fault — that
  /// is the user hiding it on purpose, which must be left alone.
  ///
  /// `hasScreen` is deliberately *not* part of this test, though it looks like
  /// it should be. A healthy item reports `window.screen == nil` whenever its
  /// menu bar isn't currently drawn — which on this machine is the normal state
  /// for an item on a display running a fullscreen Split View space. Including
  /// it flagged a perfectly visible icon as hidden. It stays in the snapshot
  /// because it's useful in the log, but it decides nothing.
  static func isSystemHidden(_ snapshot: Snapshot) -> Bool {
    guard snapshot.isVisible, snapshot.hasButton else { return false }
    return !snapshot.hasWindow
  }

  @MainActor
  static func snapshot(_ item: NSStatusItem) -> Snapshot {
    Snapshot(
      isVisible: item.isVisible,
      hasButton: item.button != nil,
      hasWindow: item.button?.window != nil,
      hasScreen: item.button?.window?.screen != nil,
      buttonWidth: item.button?.frame.width ?? 0)
  }

  // MARK: - Applying the repairs

  /// Run **before** creating the status item — clearing a bad position after
  /// the item exists doesn't move it. Returns the keys cleared, for the log.
  @discardableResult
  static func repairDefaults(
    _ defaults: UserDefaults = .standard,
    autosaveName: String = StatusItemRepair.autosaveName,
    maxScreenX: Double? = nil
  ) -> [String] {
    var cleared: [String] = []

    // Position: always checked. A corrupt value can be written at any time, and
    // clearing it only costs the item its remembered slot.
    let limit = maxScreenX ?? NSScreen.screens.map { Double($0.frame.maxX) }.max()
    for name in [autosaveName] + legacyNames(in: defaults) {
      let key = positionKey(name)
      if let value = defaults.object(forKey: key), shouldClearPosition(value, maxScreenX: limit) {
        defaults.removeObject(forKey: key)
        cleared.append(key)
      }
    }

    // Visibility: once only. Repeating it would override a user who later hides
    // the item on purpose.
    if !defaults.bool(forKey: didRepairKey) {
      for key in defaults.dictionaryRepresentation().keys.sorted()
      where shouldClearVisibility(
        key: key, value: defaults.object(forKey: key), autosaveName: autosaveName)
      {
        defaults.removeObject(forKey: key)
        cleared.append(key)
      }
      defaults.set(true, forKey: didRepairKey)
    }
    return cleared
  }

  private static func legacyNames(in defaults: UserDefaults) -> [String] {
    defaults.dictionaryRepresentation().keys
      .filter { $0.hasPrefix(positionPrefix) }
      .map { String($0.dropFirst(positionPrefix.count)) }
      .filter(isLegacyItemName)
      .sorted()
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let number as NSNumber: return number.boolValue
    case let bool as Bool: return bool
    default: return nil
    }
  }
}
