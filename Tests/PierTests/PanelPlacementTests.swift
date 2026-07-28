import XCTest

@testable import Pier

/// Placement of the menu bar panel. These cases come from real multi-display
/// readings taken with `--probe-anchor`, where NSPopover put the panel on the
/// wrong screen entirely (button at x4766, popover at x0).
final class PanelPlacementTests: XCTestCase {
  private let size = NSSize(width: 480, height: 560)
  /// A 2560×1080 display offset to the right, menu bar 30pt tall.
  private let screen = NSRect(x: 3008, y: 178, width: 2560, height: 1080)
  private var visible: NSRect {
    NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - 30)
  }

  /// Left-aligned, like a menu bar menu: the panel's left edge under the
  /// button's left edge, not centered on it.
  func testLeftAlignsToTheButton() {
    // Far enough from the right edge that no clamping applies.
    let button = NSRect(x: 4000, y: visible.maxY, width: 57, height: 22)
    let frame = PanelPlacement.frame(buttonRect: button, visibleFrame: visible, size: size)
    XCTAssertEqual(frame.minX, button.minX, accuracy: 1)
    XCTAssertNotEqual(frame.midX, button.midX, accuracy: 1, "must not be centered")
    XCTAssertEqual(frame.width, size.width)
    XCTAssertEqual(frame.height, size.height)
  }

  func testHangsBelowTheButtonByTheGap() {
    let button = NSRect(x: 4000, y: visible.maxY, width: 57, height: 22)
    let frame = PanelPlacement.frame(buttonRect: button, visibleFrame: visible, size: size)
    XCTAssertEqual(button.minY - frame.maxY, PanelPlacement.gap, accuracy: 0.5)
  }

  /// The regression that made the panel's top hide behind the menu bar: the
  /// status bar window reports a Y above its own screen frame.
  func testButtonAboveScreenFrameStillLandsUnderTheMenuBar() {
    let button = NSRect(x: 4774, y: 1294, width: 49, height: 22)  // 66pt above visible.maxY
    XCTAssertGreaterThan(button.minY, visible.maxY, "precondition: button above usable area")
    let frame = PanelPlacement.frame(buttonRect: button, visibleFrame: visible, size: size)
    XCTAssertTrue(
      visible.contains(frame), "panel must sit fully inside the usable area, got \(frame)")
    XCTAssertEqual(visible.maxY - frame.maxY, PanelPlacement.gap, accuracy: 0.5)
  }

  /// A right-hand item can't be left-aligned without hanging off the display,
  /// so it slides inward — which is what makes it look right-aligned. Most menu
  /// bar items live here, so this is the common case, not the exception.
  func testSlidesInwardAtTheRightEdge() {
    let button = NSRect(x: visible.maxX - 30, y: visible.maxY, width: 22, height: 22)
    let frame = PanelPlacement.frame(buttonRect: button, visibleFrame: visible, size: size)
    XCTAssertEqual(frame.maxX, visible.maxX - PanelPlacement.screenMargin, accuracy: 0.5)
    XCTAssertLessThan(frame.minX, button.minX, "should shift left to stay on screen")
    XCTAssertTrue(visible.contains(frame))
  }

  func testSlidesInwardAtTheLeftEdge() {
    let button = NSRect(x: visible.minX + 4, y: visible.maxY, width: 22, height: 22)
    let frame = PanelPlacement.frame(buttonRect: button, visibleFrame: visible, size: size)
    XCTAssertEqual(frame.minX, visible.minX + PanelPlacement.screenMargin, accuracy: 0.5)
    XCTAssertTrue(visible.contains(frame))
  }

  func testStaysOnScreenWhenTallerThanTheDisplay() {
    let shortScreen = NSRect(x: 0, y: 0, width: 1440, height: 400)
    let button = NSRect(x: 700, y: shortScreen.maxY, width: 57, height: 22)
    let frame = PanelPlacement.frame(
      buttonRect: button, visibleFrame: shortScreen, size: size)
    XCTAssertEqual(frame.minY, shortScreen.minY + PanelPlacement.screenMargin, accuracy: 0.5)
  }

  /// Placement must land on the button's own display, not the primary one.
  func testUsesTheButtonsDisplayNotTheOrigin() {
    let button = NSRect(x: 4766, y: 1294, width: 57, height: 22)
    let frame = PanelPlacement.frame(buttonRect: button, visibleFrame: visible, size: size)
    XCTAssertGreaterThan(frame.minX, screen.minX, "must not fall back to x0")
    XCTAssertTrue(visible.contains(frame))
  }

  func testWithoutScreenInfoFallsBackToPlainAnchoring() {
    let button = NSRect(x: 500, y: 900, width: 57, height: 22)
    let frame = PanelPlacement.frame(buttonRect: button, visibleFrame: nil, size: size)
    XCTAssertEqual(frame.minX, button.minX, accuracy: 1)
    XCTAssertEqual(button.minY - frame.maxY, PanelPlacement.gap, accuracy: 0.5)
  }
}

/// Placement when the menu bar reserves nothing — a fullscreen space, or
/// auto-hide with the bar currently hidden. The status item then reports a Y
/// *above* the screen frame, and the panel must still hang from the top of the
/// usable area rather than from a bar that isn't there.
final class HiddenMenuBarPlacementTests: XCTestCase {
  private let size = NSSize(width: 440, height: 560)
  /// Fullscreen: visibleFrame == frame, nothing reserved for the bar.
  private let screen = NSRect(x: 0, y: 0, width: 3008, height: 1692)

  func testAnchorsToTheTopWhenNothingIsReserved() {
    // Real reading from `--probe-anchor` in this state: the item sits 36pt above
    // the screen's own frame.
    let button = NSRect(x: 2113, y: 1728, width: 57, height: 22)
    XCTAssertGreaterThan(button.minY, screen.maxY, "precondition: item above the screen")

    let frame = PanelPlacement.frame(buttonRect: button, visibleFrame: screen, size: size)
    XCTAssertEqual(screen.maxY - frame.maxY, PanelPlacement.gap, accuracy: 0.5)
    XCTAssertTrue(screen.contains(frame), "must be fully on screen, got \(frame)")
  }

  /// The same item with the bar shown lands 30pt lower. That difference is what
  /// `followMenuBarIfNeeded` moves the panel by when the bar hides mid-session —
  /// and it's far larger than the 4pt slack that ignores item jitter.
  func testShownVsHiddenDiffersByTheBarHeight() {
    let barHeight: CGFloat = 30
    let withBar = NSRect(
      x: 0, y: 0, width: screen.width, height: screen.height - barHeight)
    let button = NSRect(x: 2113, y: 1728, width: 57, height: 22)

    let hidden = PanelPlacement.frame(buttonRect: button, visibleFrame: screen, size: size)
    let shown = PanelPlacement.frame(buttonRect: button, visibleFrame: withBar, size: size)

    XCTAssertEqual(hidden.maxY - shown.maxY, barHeight, accuracy: 0.5)
    XCTAssertGreaterThan(hidden.maxY - shown.maxY, 4, "must exceed the anti-jitter slack")
    XCTAssertEqual(hidden.minX, shown.minX, "horizontal anchor is unaffected")
  }

  /// A short screen with no bar still can't push the panel off the bottom.
  func testClampsOnAShortScreenWithNoBar() {
    let short = NSRect(x: 0, y: 0, width: 1440, height: 500)
    let button = NSRect(x: 700, y: short.maxY + 10, width: 57, height: 22)
    let frame = PanelPlacement.frame(buttonRect: button, visibleFrame: short, size: size)
    XCTAssertEqual(frame.minY, short.minY + PanelPlacement.screenMargin, accuracy: 0.5)
  }
}

/// Detecting whether the menu bar is actually drawn. This exists because the
/// obvious signals don't move: measured over 12s of the bar auto-hiding and
/// revealing, `NSMenu.menuBarVisible()` stayed true, `NSStatusBar.thickness`
/// stayed 22, and `NSScreen.visibleFrame` never changed — a display hosting a
/// fullscreen space reports 0pt reserved whether the bar is up or not. The menu
/// bar's own window *does* drop out of the on-screen list, so that's the signal.
final class MenuBarVisibilityTests: XCTestCase {
  /// Real reading: a 1512×982 display at Cocoa y-813, its bar reported by
  /// CGWindowList as x3008 y1523 1512×33 (top-left origin, primary is 1692 tall).
  func testConvertsWindowListBoundsToCocoa() {
    let converted = MenuBarVisibility.cocoaRect(
      fromWindowBounds: CGRect(x: 3008, y: 1523, width: 1512, height: 33),
      primaryHeight: 1692)
    XCTAssertEqual(converted.minX, 3008)
    XCTAssertEqual(converted.maxY, 169, "flush with that screen's top edge")
    XCTAssertEqual(converted.height, 33)
  }

  func testDetectsTheBarOnItsOwnScreen() {
    let screen = CGRect(x: 3008, y: -813, width: 1512, height: 982)  // top at y169
    let bar = CGRect(x: 3008, y: 136, width: 1512, height: 33)  // maxY 169
    XCTAssertTrue(MenuBarVisibility.barCovers(screenFrame: screen, barRects: [bar]))
  }

  /// A bar drawn on a *different* display must not count as this one's.
  func testBarOnAnotherScreenDoesNotCount() {
    let fullscreen = CGRect(x: 3008, y: 178, width: 2560, height: 1080)
    let otherBar = CGRect(x: 0, y: 1662, width: 3008, height: 30)  // the primary's
    XCTAssertFalse(MenuBarVisibility.barCovers(screenFrame: fullscreen, barRects: [otherBar]))
    XCTAssertFalse(
      MenuBarVisibility.barCovers(screenFrame: fullscreen, barRects: []),
      "no bars drawn at all means not visible")
  }

  /// The placement consequence: with the bar retracted, the panel hangs from the
  /// screen top rather than from the item's stale Y — which is the ~30pt of empty
  /// space that made the panel look detached.
  func testRetractedBarAnchorsToTheScreenTop() {
    let visible = CGRect(x: 3008, y: 178, width: 2560, height: 1080)  // 0pt reserved
    let staleButton = NSRect(x: 4000, y: visible.maxY - 22, width: 57, height: 22)
    let size = NSSize(width: 440, height: 560)

    let shown = PanelPlacement.frame(
      buttonRect: staleButton, visibleFrame: visible, size: size, barVisible: true)
    let retracted = PanelPlacement.frame(
      buttonRect: staleButton, visibleFrame: visible, size: size, barVisible: false)

    XCTAssertEqual(visible.maxY - retracted.maxY, PanelPlacement.gap, accuracy: 0.5)
    XCTAssertEqual(retracted.maxY - shown.maxY, 22, accuracy: 0.5, "moves up by the bar")
    XCTAssertEqual(retracted.minX, shown.minX, "horizontal anchor unaffected")
  }
}
