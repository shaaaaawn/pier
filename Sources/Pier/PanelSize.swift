import AppKit

/// The panel's user-adjustable size, persisted across launches.
///
/// The panel is borderless (it hangs off the menu bar), so it gets no system
/// resize handles — the grabber in the footer writes here and the controller
/// reacts to `didChange`.
enum PanelSize {
  static let defaultWidth: CGFloat = 440
  static let defaultHeight: CGFloat = 560
  static let minWidth: CGFloat = 340
  static let maxWidth: CGFloat = 760
  static let minHeight: CGFloat = 300
  static let maxHeight: CGFloat = 1000

  static let widthKey = "panelWidth"
  static let heightKey = "panelHeight"

  /// Posted after a size change so the panel window can follow.
  static let didChange = Notification.Name("PierPanelSizeDidChange")

  /// Which dimensions a drag handle changes.
  struct Axes: Equatable {
    let horizontal: Bool
    let vertical: Bool

    static let both = Axes(horizontal: true, vertical: true)
    static let horizontalOnly = Axes(horizontal: true, vertical: false)
    static let verticalOnly = Axes(horizontal: false, vertical: true)
  }

  /// New size for a resize drag, computed from **absolute screen positions**.
  ///
  /// Not from a SwiftUI drag translation: the handle lives at the panel's
  /// bottom-right, so growing the window moves the handle along with the
  /// pointer. Translation measured in the handle's own coordinate space then
  /// stops accumulating and the resize stalls after a few points. Screen
  /// coordinates don't move when the window does.
  ///
  /// AppKit screen space has y increasing *upward*, so dragging down (smaller y)
  /// must make the panel taller — it hangs from the menu bar and grows downward.
  static func dragged(
    from start: NSSize, startMouse: NSPoint, currentMouse: NSPoint, axes: Axes = .both
  ) -> NSSize {
    var size = start
    if axes.horizontal { size.width = start.width + (currentMouse.x - startMouse.x) }
    if axes.vertical { size.height = start.height + (startMouse.y - currentMouse.y) }
    return clamp(size)
  }

  static func clamp(_ size: NSSize) -> NSSize {
    NSSize(
      width: min(max(minWidth, size.width), maxWidth).rounded(),
      height: min(max(minHeight, size.height), maxHeight).rounded())
  }

  /// Stored size, clamped. Falls back to the defaults when unset.
  static var current: NSSize {
    let defaults = UserDefaults.standard
    let width = defaults.object(forKey: widthKey) as? Double ?? defaultWidth
    let height = defaults.object(forKey: heightKey) as? Double ?? defaultHeight
    return clamp(NSSize(width: width, height: height))
  }

  /// Persist a new size (clamped) and notify. No-op when nothing changed, so a
  /// drag that hits a clamp doesn't spam the window with identical frames.
  static func set(_ size: NSSize) {
    let clamped = clamp(size)
    guard clamped != current else { return }
    UserDefaults.standard.set(Double(clamped.width), forKey: widthKey)
    UserDefaults.standard.set(Double(clamped.height), forKey: heightKey)
    NotificationCenter.default.post(name: didChange, object: nil)
  }

  static func reset() {
    UserDefaults.standard.removeObject(forKey: widthKey)
    UserDefaults.standard.removeObject(forKey: heightKey)
    NotificationCenter.default.post(name: didChange, object: nil)
  }
}
