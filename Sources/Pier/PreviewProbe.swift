import AppKit
import SwiftUI

/// `--probe-preview <port> <out.png>`: the real panel, live data, with that
/// port's row expanded into its preview — rendered offscreen after a few
/// seconds. Answers "does clicking this row open a working preview?" without
/// clicking: the same view tree, the same `PortPreviewView` loading the same
/// URL, under whatever scope chip the running app has selected.
enum PreviewProbe {
  @MainActor
  static func run(port: Int, out: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let monitor = PortMonitor()
    let deadline = Date().addingTimeInterval(45)
    while monitor.lastRefresh == nil, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    guard let entry = monitor.entries.first(where: { $0.port == port && $0.proto == .tcp }) else {
      print("no TCP listener on :\(port)")
      exit(1)
    }
    print(
      "entry: \(entry.id) bind=\(entry.bindSummary) url=\(entry.previewURL?.absoluteString ?? "nil")"
    )
    print(
      "dev: \(entry.dev?.label ?? "-") · scope: \(UserDefaults.standard.string(forKey: "listFilter") ?? "all")"
    )
    monitor.windowVisible = true
    let size = NSSize(width: PortListView.panelWidth, height: PortListView.panelHeight)
    let hosting = NSHostingView(
      rootView: PortListView(initialExpandedID: entry.id, initialMode: .preview)
        .environmentObject(monitor))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(6))
    hosting.layoutSubtreeIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
    exit(0)
  }
}

/// `--probe-click <port> <dir>`: real mouse clicks, delivered through
/// `NSWindow.sendEvent` to the same borderless non-activating panel the app
/// uses, on the row for `port` — first with the panel **not** key (the state
/// it's in after focus moves elsewhere), then again. Renders after each click,
/// so "clicking the row doesn't open the preview" can be seen, not guessed.
enum ClickProbe {
  @MainActor
  static func run(port: Int, dir: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let monitor = PortMonitor()
    let deadline = Date().addingTimeInterval(45)
    while monitor.lastRefresh == nil, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    monitor.windowVisible = true
    let size = NSSize(width: PortListView.panelWidth, height: PortListView.panelHeight)
    let panel = PanelWindow(
      contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // The production window class, so the probe tests what ships.
    let hosting = NSHostingView(rootView: PortListView().environmentObject(monitor))
    panel.contentView = hosting
    panel.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))

    // The AX tree is built lazily and is empty with no assistive client, so
    // the row is located by its offset from the top (PIER_PROBE_ROW_Y, pt) —
    // the before/after renders show whether the click landed on it.
    let fromTop = Double(ProcessInfo.processInfo.environment["PIER_PROBE_ROW_Y"] ?? "128") ?? 128
    let point = NSPoint(x: 260, y: size.height - fromTop)
    render(hosting, to: "\(dir)/click0.png")
    print(
      "row :\(port) at window \(Int(point.x)),\(Int(point.y)); key before click 1: \(panel.isKeyWindow)"
    )

    for attempt in 1...2 {
      click(panel, at: point)
      RunLoop.current.run(until: Date().addingTimeInterval(1.5))
      print("after click \(attempt): key=\(panel.isKeyWindow)")
      render(hosting, to: "\(dir)/click\(attempt).png")
    }
    exit(0)
  }

  @MainActor
  static func click(_ window: NSWindow, at point: NSPoint) {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
      {
        window.sendEvent(event)
      }
    }
  }

  @MainActor
  static func render(_ view: NSView, to path: String) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }
}
