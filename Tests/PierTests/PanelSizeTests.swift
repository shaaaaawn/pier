import XCTest

@testable import Pier

final class PanelSizeTests: XCTestCase {
  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: PanelSize.widthKey)
    UserDefaults.standard.removeObject(forKey: PanelSize.heightKey)
    super.tearDown()
  }

  func testDefaultsWhenUnset() {
    UserDefaults.standard.removeObject(forKey: PanelSize.widthKey)
    UserDefaults.standard.removeObject(forKey: PanelSize.heightKey)
    XCTAssertEqual(PanelSize.current.width, PanelSize.defaultWidth)
    XCTAssertEqual(PanelSize.current.height, PanelSize.defaultHeight)
  }

  func testClampsToBounds() {
    let tooSmall = PanelSize.clamp(NSSize(width: 10, height: 10))
    XCTAssertEqual(tooSmall.width, PanelSize.minWidth)
    XCTAssertEqual(tooSmall.height, PanelSize.minHeight)

    let tooBig = PanelSize.clamp(NSSize(width: 5000, height: 5000))
    XCTAssertEqual(tooBig.width, PanelSize.maxWidth)
    XCTAssertEqual(tooBig.height, PanelSize.maxHeight)
  }

  func testClampRoundsToWholePoints() {
    let size = PanelSize.clamp(NSSize(width: 440.4, height: 560.6))
    XCTAssertEqual(size.width, 440)
    XCTAssertEqual(size.height, 561)
  }

  func testSetPersistsClampedValue() {
    PanelSize.set(NSSize(width: 600, height: 700))
    XCTAssertEqual(PanelSize.current, NSSize(width: 600, height: 700))

    // Dragging past the max stores the max, not the raw value.
    PanelSize.set(NSSize(width: 9999, height: 700))
    XCTAssertEqual(PanelSize.current.width, PanelSize.maxWidth)
  }

  func testResetRestoresDefaults() {
    PanelSize.set(NSSize(width: 600, height: 700))
    PanelSize.reset()
    XCTAssertEqual(PanelSize.current.width, PanelSize.defaultWidth)
    XCTAssertEqual(PanelSize.current.height, PanelSize.defaultHeight)
  }

  /// A drag that pushes past a clamp shouldn't keep posting identical frames.
  func testSetAtClampDoesNotNotifyRepeatedly() {
    PanelSize.set(NSSize(width: PanelSize.maxWidth, height: PanelSize.defaultHeight))
    // Posted synchronously, so an inverted expectation fails the moment one
    // arrives; the short wait only bounds the test.
    let posted = expectation(forNotification: PanelSize.didChange, object: nil)
    posted.isInverted = true

    PanelSize.set(NSSize(width: PanelSize.maxWidth + 200, height: PanelSize.defaultHeight))
    PanelSize.set(NSSize(width: PanelSize.maxWidth + 400, height: PanelSize.defaultHeight))
    wait(for: [posted], timeout: 0.1)
  }

  /// The slimmer default still leaves a sane desktop-preview zoom.
  func testDefaultWidthKeepsPreviewViewportUsable() {
    let cardWidth = PanelSize.defaultWidth - 24
    let zoom = PreviewViewport.desktop.zoom(cardWidth: cardWidth)
    XCTAssertEqual(cardWidth / zoom, 1280, accuracy: 1.0)
    XCTAssertGreaterThan(zoom, 0.2, "must not hit the zoom clamp at the default width")
  }
}

/// Resize math. The bug this replaces: SwiftUI's drag translation was measured
/// in the grip's own coordinate space, and the grip sits at the panel's
/// bottom-right — so growing the window moved the grip along with the pointer,
/// the translation stopped accumulating, and the resize stalled after a few
/// points. Screen coordinates don't move when the window does.
final class PanelResizeDragTests: XCTestCase {
  private let start = NSSize(width: 440, height: 560)

  func testDraggingRightAndDownGrows() {
    // Screen space: y increases upward, so "down" is a smaller y.
    let size = PanelSize.dragged(
      from: start, startMouse: NSPoint(x: 1000, y: 800),
      currentMouse: NSPoint(x: 1080, y: 700))
    XCTAssertEqual(size.width, 520)
    XCTAssertEqual(size.height, 660)
  }

  func testDraggingLeftAndUpShrinks() {
    let size = PanelSize.dragged(
      from: start, startMouse: NSPoint(x: 1000, y: 800),
      currentMouse: NSPoint(x: 960, y: 830))
    XCTAssertEqual(size.width, 400)
    XCTAssertEqual(size.height, 530)
  }

  func testEdgeHandlesMoveOnlyTheirOwnAxis() {
    let mouseStart = NSPoint(x: 1000, y: 800)
    let mouseNow = NSPoint(x: 1100, y: 700)

    let horizontal = PanelSize.dragged(
      from: start, startMouse: mouseStart, currentMouse: mouseNow, axes: .horizontalOnly)
    XCTAssertEqual(horizontal.width, 540)
    XCTAssertEqual(horizontal.height, start.height, "right edge must not change height")

    let vertical = PanelSize.dragged(
      from: start, startMouse: mouseStart, currentMouse: mouseNow, axes: .verticalOnly)
    XCTAssertEqual(vertical.width, start.width, "bottom edge must not change width")
    XCTAssertEqual(vertical.height, 660)
  }

  /// Dragging far past a limit clamps instead of running away, and the size is
  /// a pure function of the *original* size plus total pointer delta — so a
  /// drag that goes out and comes back lands where it started.
  func testDragIsAbsoluteAndClamped() {
    let huge = PanelSize.dragged(
      from: start, startMouse: NSPoint(x: 0, y: 1000),
      currentMouse: NSPoint(x: 4000, y: -4000))
    XCTAssertEqual(huge.width, PanelSize.maxWidth)
    XCTAssertEqual(huge.height, PanelSize.maxHeight)

    let returned = PanelSize.dragged(
      from: start, startMouse: NSPoint(x: 500, y: 500),
      currentMouse: NSPoint(x: 500, y: 500))
    XCTAssertEqual(returned, start, "no movement means no change")
  }
}
