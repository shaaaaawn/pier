import AppKit

/// Whether the menu bar is *currently drawn* on a given display.
///
/// None of the obvious APIs answer this. Measured over 12s while the bar
/// auto-hid and revealed (`--watch-menubar`): `NSMenu.menuBarVisible()` stays
/// `true`, `NSStatusBar.system.thickness` stays 22, and `NSScreen.visibleFrame`
/// never changes — a display hosting a fullscreen space simply reports 0pt
/// reserved at all times, whether the bar is revealed or not.
///
/// What *does* move is the menu bar's own window. The window server keeps one
/// thin, full-width window at layer 24 per drawn menu bar, and it drops out of
/// the on-screen list when the bar hides. Bounds and owner are readable without
/// Screen Recording permission (only window *contents* and names need it).
enum MenuBarVisibility {
  /// Window layer the menu bar lives on.
  static let menuBarLayer = 24

  /// Convert CGWindowList bounds (top-left origin, y down, relative to the
  /// primary display) into Cocoa screen coordinates (bottom-left origin, y up).
  static func cocoaRect(fromWindowBounds bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(
      x: bounds.minX,
      y: primaryHeight - bounds.maxY,
      width: bounds.width,
      height: bounds.height)
  }

  /// Does one of `barRects` sit along `screen`'s top edge?
  static func barCovers(screenFrame: CGRect, barRects: [CGRect], tolerance: CGFloat = 4)
    -> Bool
  {
    barRects.contains { bar in
      // Same horizontal span, and flush with this screen's top.
      bar.midX > screenFrame.minX && bar.midX < screenFrame.maxX
        && abs(bar.maxY - screenFrame.maxY) <= tolerance
    }
  }

  /// Thin, full-width, high-layer windows — the menu bars currently drawn.
  static func barRects() -> [CGRect] {
    let primaryHeight =
      NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
      ?? NSScreen.main?.frame.height ?? 0
    guard primaryHeight > 0,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }

    return windows.compactMap { window in
      guard let layer = window[kCGWindowLayer as String] as? Int, layer >= menuBarLayer,
        let raw = window[kCGWindowBounds as String] as? [String: CGFloat],
        let height = raw["Height"], let width = raw["Width"],
        height > 0, height <= 40, width > 500
      else { return nil }
      let bounds = CGRect(
        x: raw["X"] ?? 0, y: raw["Y"] ?? 0, width: width, height: height)
      return cocoaRect(fromWindowBounds: bounds, primaryHeight: primaryHeight)
    }
  }

  /// Is the menu bar drawn on this screen right now? Thin wrapper — it asks the
  /// window server, then defers to the pure form below.
  static func isBarVisible(on screen: NSScreen?) -> Bool {
    guard let screen else { return true }  // unknown → behave as today
    return isBarVisible(
      screenFrame: screen.frame, visibleFrame: screen.visibleFrame, barRects: barRects())
  }

  /// The decision, with the world as arguments so it can be tested against
  /// captured window-server records instead of a live display. Same reason the
  /// CLI parsers take captured output.
  static func isBarVisible(
    screenFrame: CGRect, visibleFrame: CGRect, barRects: [CGRect]
  ) -> Bool {
    // A display that permanently reserves space always shows its bar; one that
    // reserves none is in a fullscreen space, where the bar is only drawn while
    // the pointer holds it open.
    if screenFrame.maxY - visibleFrame.maxY > 1 { return true }
    return barCovers(screenFrame: screenFrame, barRects: barRects)
  }
}
