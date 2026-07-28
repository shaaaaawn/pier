import AppKit
import SwiftUI

/// AppKit resize handle for the panel's edges and corner.
///
/// Deliberately *not* a SwiftUI `DragGesture`: the panel size lives in
/// `UserDefaults`, `PortListView` reads it through `@AppStorage`, and persisting
/// on every drag tick therefore rebuilt the whole list — every row, badge and
/// sparkline — dozens of times a second. The resize worked but lagged badly
/// behind the pointer.
///
/// This handle resizes the **window** directly on each `mouseDragged` and
/// persists exactly once on mouse-up. AppKit's autoresizing reflows the hosted
/// SwiftUI content, so nothing rebuilds from state mid-drag.
final class ResizeHandleView: NSView {
  var axes: PanelSize.Axes = .both
  /// Double-click restores the default size (corner grip only).
  var resetsOnDoubleClick = false

  private var startMouse: NSPoint = .zero
  private var startSize: NSSize = .zero

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: cursor)
  }

  private var cursor: NSCursor {
    switch (axes.horizontal, axes.vertical) {
    case (true, false): return .resizeLeftRight
    case (false, true): return .resizeUpDown
    default:
      // No public diagonal cursor before macOS 15; the visible grip glyph
      // carries the affordance there.
      if #available(macOS 15.0, *) {
        return .frameResize(position: .bottomRight, directions: .all)
      }
      return .crosshair
    }
  }

  override func mouseDown(with event: NSEvent) {
    if resetsOnDoubleClick, event.clickCount == 2 {
      PanelSize.reset()
      return
    }
    startMouse = NSEvent.mouseLocation
    startSize = window?.frame.size ?? PanelSize.current
  }

  override func mouseDragged(with event: NSEvent) {
    guard let window else { return }
    let size = PanelSize.dragged(
      from: startSize, startMouse: startMouse, currentMouse: NSEvent.mouseLocation, axes: axes)
    guard size != window.frame.size else { return }

    // Top edge stays planted: the panel hangs from the menu bar, so it grows
    // downward rather than sliding out from under the pointer.
    var frame = window.frame
    frame.origin.y = frame.maxY - size.height
    frame.size = size
    if let visible = window.screen?.visibleFrame {
      let margin = PanelPlacement.screenMargin
      frame.origin.x = min(frame.origin.x, visible.maxX - size.width - margin)
      frame.origin.x = max(frame.origin.x, visible.minX + margin)
      frame.origin.y = max(frame.origin.y, visible.minY + margin)
    }
    // display:false lets AppKit coalesce the redraw with the next cycle
    // instead of forcing a synchronous one per mouse event.
    window.setFrame(frame, display: false)
  }

  override func mouseUp(with event: NSEvent) {
    // One write, one notification, one SwiftUI rebuild — at the end.
    guard let size = window?.frame.size else { return }
    PanelSize.set(size)
  }
}

/// SwiftUI wrapper so the handle can be placed in the panel's layout.
struct ResizeHandle: NSViewRepresentable {
  var axes: PanelSize.Axes = .both
  var resetsOnDoubleClick = false

  func makeNSView(context: Context) -> ResizeHandleView {
    let view = ResizeHandleView()
    view.axes = axes
    view.resetsOnDoubleClick = resetsOnDoubleClick
    return view
  }

  func updateNSView(_ nsView: ResizeHandleView, context: Context) {
    nsView.axes = axes
    nsView.resetsOnDoubleClick = resetsOnDoubleClick
  }
}
