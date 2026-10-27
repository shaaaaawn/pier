import AppKit
import Combine
import SwiftUI

/// Borderless panel that still takes key focus, so the search field works.
/// A plain borderless NSPanel refuses key status by default.
///
/// It also acts on the **first** click. The panel is non-activating — it opens
/// over whatever app you're in without taking focus from it — so it often
/// isn't key when you click it, and AppKit then spends that click making it
/// key and delivers nothing: clicking a port to preview it did nothing, and
/// only a second click worked. `acceptsFirstMouse` on the content view can't
/// fix it — the click lands on SwiftUI's own internal views (the list's
/// scroll view), which answer for themselves. Becoming key before AppKit
/// looks means the click is delivered like any other. Reproduced and verified
/// with `--probe-click`.
final class PanelWindow: NSPanel {
  override var canBecomeKey: Bool { true }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow {
      makeKey()
    }
    super.sendEvent(event)
  }
}

/// Where the panel goes relative to its menu bar item. Pure geometry, kept
/// out of the controller so it can be unit-tested.
enum PanelPlacement {
  /// Gap between the menu bar item and the panel's top edge.
  static let gap: CGFloat = 6
  /// Inset kept from a screen edge when the panel would overflow.
  static let screenMargin: CGFloat = 8

  /// **Left-aligned** to the status item — the panel's left edge sits under the
  /// button's left edge, the way a menu bar menu opens — and hanging from
  /// whichever is lower: the button's bottom edge or the top of the usable area.
  ///
  /// Two real-world cases drive the rest: the per-display status bar window can
  /// report a Y *above* its own screen frame (which would tuck the panel's top
  /// up behind the menu bar), and an item close to the right edge needs the
  /// panel to slide inward rather than hang off — which is what makes a
  /// right-hand item's panel appear right-aligned instead.
  /// `barVisible == false` means the menu bar isn't drawn on this display right
  /// now (a fullscreen space, or auto-hide with the bar retracted). The item
  /// isn't on screen either, so its Y is a stale reading of where the bar *was*;
  /// anchoring to it leaves the panel floating a bar's height below nothing.
  /// Hang from the top of the usable area instead.
  static func frame(
    buttonRect: NSRect, visibleFrame: NSRect?, size: NSSize,
    barVisible: Bool = true,
    gap: CGFloat = gap, margin: CGFloat = screenMargin
  ) -> NSRect {
    var x = buttonRect.minX
    var y = buttonRect.minY - size.height - gap
    if let visible = visibleFrame {
      x = min(max(visible.minX + margin, x), visible.maxX - size.width - margin)
      let top = barVisible ? min(buttonRect.minY, visible.maxY) : visible.maxY
      y = top - size.height - gap
      y = max(y, visible.minY + margin)
    }
    return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
  }

  /// No usable button rect: hang from the top-right of the usable area.
  static func unanchored(
    visibleFrame: NSRect?, size: NSSize, gap: CGFloat = gap, margin: CGFloat = screenMargin
  ) -> NSRect {
    guard let visible = visibleFrame else { return NSRect(origin: .zero, size: size) }
    return NSRect(
      x: (visible.maxX - size.width - margin).rounded(),
      y: (visible.maxY - size.height - gap).rounded(),
      width: size.width, height: size.height)
  }
}

/// Owns the menu bar presence: an `NSStatusItem` plus a panel positioned
/// directly under its button.
///
/// Why not SwiftUI's `MenuBarExtra`, and why not `NSPopover`: with more than
/// one display macOS installs a status-bar window *per screen*, and both of
/// those place their window on the wrong one — the panel lands at the primary
/// screen's left edge while the icon sits on another display. (Verified with
/// `--probe-anchor`: button at x4766, popover at x0.) Computing the frame from
/// the live button rect is deterministic, works on every display, and survives
/// the menu bar being hidden in fullscreen or auto-hide.
@MainActor
final class MenuBarController: NSObject {
  let monitor = PortMonitor()
  /// RAM vs swap for the footer glance. Samples only while the panel is open.
  let memory = MemoryMonitor()

  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let panel: PanelWindow
  private var dismissMonitor: Any?
  private var keyMonitor: Any?
  /// The button rect the panel was last aligned to (debug: the item can move
  /// after opening, when its own title width changes).
  private var lastAnchorRect: NSRect = .zero
  private var cancellables: Set<AnyCancellable> = []

  override init() {
    let size = PanelSize.current
    panel = PanelWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    super.init()

    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .utilityWindow

    let hosting = NSHostingView(
      rootView: PortListView()
        .environmentObject(monitor)
        .environment(\.memoryMonitor, memory))
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.autoresizingMask = [.width, .height]
    hosting.wantsLayer = true
    hosting.layer?.cornerRadius = 12
    hosting.layer?.cornerCurve = .continuous
    hosting.layer?.masksToBounds = true
    panel.contentView = hosting

    if let button = statusItem.button {
      button.image = Self.icon
      button.imagePosition = .imageLeading
      // Monospaced digits so the item doesn't jitter as the count changes.
      button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      button.target = self
      button.action = #selector(togglePanel)
      button.toolTip = "Pier — listening ports"
    }
    // Without this macOS keys the item's saved position and visibility by
    // launch-order index, which moves between runs — see StatusItemRepair.
    statusItem.autosaveName = StatusItemRepair.autosaveName
    watchStatusItemVisibility()
    updateTitle(monitor.tcpCount, unseen: 0)

    monitor.$entries
      .receive(on: RunLoop.main)
      .sink { [weak self] entries in
        self?.portCount = entries.filter { $0.proto == .tcp }.count
        self?.refreshTitle()
      }
      .store(in: &cancellables)

    memory.$thermal
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] level in
        if level != self?.thermal { PierLog.shared.log("thermal state: \(level.label)") }
        self?.thermal = level
        self?.refreshTitle()
      }
      .store(in: &cancellables)

    memory.$pressure
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] level in
        if level != self?.memoryPressure {
          PierLog.shared.log("memory pressure: \(level.label)")
        }
        self?.memoryPressure = level
        self?.refreshTitle()
      }
      .store(in: &cancellables)

    monitor.$unseenEvents
      .receive(on: RunLoop.main)
      .sink { [weak self] unseen in
        self?.unseenEvents = unseen
        self?.refreshTitle()
      }
      .store(in: &cancellables)

    NotificationCenter.default
      .publisher(for: PanelSize.didChange)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.applyStoredSize() }
      .store(in: &cancellables)
  }

  /// Follow a resize from the grabber. Keeps the top-left corner planted so the
  /// panel grows right/down under the pointer instead of jumping mid-drag (it
  /// re-anchors to the icon on the next open), and nudges back inside the screen
  /// if the new size would overflow.
  private func applyStoredSize() {
    let size = PanelSize.current
    guard panel.frame.size != size else { return }
    var frame = panel.frame
    frame.origin.y = frame.maxY - size.height
    frame.size = size
    if let visible = buttonScreen()?.visibleFrame {
      let margin = PanelPlacement.screenMargin
      frame.origin.x = min(frame.origin.x, visible.maxX - size.width - margin)
      frame.origin.x = max(frame.origin.x, visible.minX + margin)
      frame.origin.y = max(frame.origin.y, visible.minY + margin)
    }
    panel.setFrame(frame, display: true)
  }

  /// Template image: AppKit paints it with the menu bar's own foreground
  /// color, so it inverts automatically — dark glyph on a light menu bar,
  /// light glyph on a dark one — and picks up the highlight tint while the
  /// panel is open. The PNG is a solid black glyph whose alpha is the shape.
  private static let icon: NSImage? = {
    guard let image = Bundle.module.image(forResource: "menubar-icon") else { return nil }
    image.isTemplate = true
    image.size = NSSize(width: 16, height: 16)
    return image
  }()

  private var portCount = 0
  private var memoryPressure: MemoryPressure = .normal
  private var thermal: ThermalLevel = .nominal
  private var unseenEvents = 0

  private func refreshTitle() {
    updateTitle(portCount, unseen: unseenEvents)
  }

  /// Notices when the system has taken the status item away. Nothing can undo
  /// that from inside the app, but "macOS hid the icon" is a different answer
  /// from "Pier crashed", and only the log can tell you which happened.
  ///
  /// Checked on a delay rather than immediately, and again after a display
  /// change: status item placement settles asynchronously, so an instant check
  /// reports a missing window that appears a moment later.
  private func watchStatusItemVisibility() {
    checkStatusItemVisibility(after: 2.0, reason: "launch")
    NotificationCenter.default
      .publisher(for: NSApplication.didChangeScreenParametersNotification)
      // AppKit posts this on main today. The hop makes that a guarantee: this
      // sink is main-actor code, and under Swift 6 a delivery from any other
      // thread traps, taking the status item with it.
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        // Two probes: the first catches the common case, the second covers a
        // slow re-place after a display wakes or is reconnected.
        self?.checkStatusItemVisibility(after: 0.75, reason: "screen change")
        self?.checkStatusItemVisibility(after: 2.0, reason: "screen change (follow-up)")
      }
      .store(in: &cancellables)
  }

  private func checkStatusItemVisibility(after delay: TimeInterval, reason: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      let snapshot = StatusItemRepair.snapshot(self.statusItem)
      guard StatusItemRepair.isSystemHidden(snapshot) else { return }
      PierLog.shared.log("status item hidden by the system after \(reason) — \(snapshot)")
    }
  }

  /// The glyph alone, plus a mark only while one means something (see
  /// `StatusTitle`). Memory-pressure colour appears only when the kernel says
  /// so, never for "lots of RAM used" (which is normal on macOS). The port
  /// count lives in the tooltip now, not the menu bar.
  private func updateTitle(_ count: Int, unseen: Int) {
    let title = StatusTitle.make(unseen: unseen, pressure: memoryPressure, thermal: thermal)
    statusItem.button?.attributedTitle = title
    // Image-only when there's no mark, so the item is just the glyph's width.
    statusItem.button?.imagePosition = title.length == 0 ? .imageOnly : .imageLeading
    var tip = "Pier — \(count) listening port\(count == 1 ? "" : "s")"
    if unseen > 0 { tip += "\n\(unseen) new event\(unseen == 1 ? "" : "s")" }
    if memoryPressure != .normal { tip += "\nMemory pressure: \(memoryPressure.label)" }
    if thermal.isHot { tip += "\nRunning \(thermal.label.lowercased()): \(thermal.explanation)" }
    statusItem.button?.toolTip = tip
  }

  // MARK: - Placement

  /// The status button's rect in screen coordinates, via its own (per-display)
  /// status bar window.
  private func buttonScreenRect() -> NSRect? {
    guard let button = statusItem.button, let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  /// The display the menu bar item lives on. The status bar window's own
  /// `screen` is authoritative — a frame-intersection test can miss, because
  /// the per-display status bar window sits slightly outside the screen frame
  /// it belongs to.
  private func buttonScreen() -> NSScreen? {
    if let screen = statusItem.button?.window?.screen { return screen }
    if let button = buttonScreenRect() {
      if let hit = NSScreen.screens.first(where: { $0.frame.intersects(button) }) { return hit }
      // Fall back to the nearest screen horizontally (menu bar rows can sit
      // just above their screen's frame).
      return NSScreen.screens.min {
        abs($0.frame.midX - button.midX) < abs($1.frame.midX - button.midX)
      }
    }
    return NSScreen.main
  }

  /// Panel frame left-aligned under the button, clamped into that button's screen.
  func anchoredFrame() -> NSRect {
    let size = PanelSize.current
    // No button to hang from: top-right of the main screen, where the item
    // would be, rather than the bottom-left corner a zero origin meant.
    guard let button = buttonScreenRect(),
      NSScreen.screens.contains(where: { $0.frame.intersects(button) })
    else {
      return PanelPlacement.unanchored(visibleFrame: NSScreen.main?.visibleFrame, size: size)
    }
    let screen = buttonScreen()
    return PanelPlacement.frame(
      buttonRect: button, visibleFrame: screen?.visibleFrame, size: size,
      barVisible: MenuBarVisibility.isBarVisible(on: screen))
  }

  // MARK: - Show / hide

  @objc private func togglePanel() {
    panel.isVisible ? closePanel() : showPanel()
  }

  func showPanelIfHidden() {
    if !panel.isVisible { showPanel() }
  }

  func showPanel() {
    monitor.refresh()
    lastAnchorRect = buttonScreenRect() ?? .zero
    panel.setFrame(anchoredFrame(), display: false)
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    statusItem.button?.highlight(true)
    monitor.windowVisible = true
    memory.setActive(true)
    monitor.markEventsSeen()
    installDismissMonitors()
  }

  func closePanel() {
    removeDismissMonitors()
    panel.orderOut(nil)
    statusItem.button?.highlight(false)
    monitor.windowVisible = false
    // Memory stops sampling while the panel is closed; only MemoryMonitor's
    // once-a-minute CPU + temperature tick keeps the 30-minute ranges honest.
    memory.setActive(false)
  }

  // The panel used to chase the menu bar: a 0.5s timer re-anchored it whenever
  // the bar hid or revealed, keeping it glued to the top edge.
  //
  // That solved the wrong problem. The bar hides because the display is running
  // a fullscreen space, where macOS reveals it only while the pointer is at the
  // top edge — and no ordinary window can hold it open; only a real NSMenu can,
  // which Pier deliberately isn't (docs/research/codexbar-practices.md §11). So the bar
  // was always going to hide, and chasing it turned a static ~30pt gap into the
  // panel *jumping* every time the pointer crossed the top edge. The motion is
  // what read as broken, not the gap.
  //
  // The panel now anchors once, on open, and stays put until it closes.

  /// Dismiss like a menu would: a click anywhere else, or Escape. Mouse
  /// monitors need no permissions (only key events would).
  private func installDismissMonitors() {
    guard dismissMonitor == nil else { return }
    dismissMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      guard let self, self.panel.isVisible else { return }
      let location = NSEvent.mouseLocation
      if self.panel.frame.contains(location) { return }
      // Clicks on our own status item are the toggle's business, not ours —
      // closing here first would make the toggle immediately reopen.
      if self.buttonScreenRect()?.contains(location) == true { return }
      self.closePanel()
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      guard let self, self.panel.isVisible, event.keyCode == 53 else { return event }
      self.closePanel()
      return nil  // swallow the Escape
    }
  }

  private func removeDismissMonitors() {
    if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    dismissMonitor = nil
    keyMonitor = nil
  }

  // MARK: - Debug

  /// Drive the real button action, the way a click would.
  func simulateClick() {
    statusItem.button?.performClick(nil)
  }

  /// Debug: per-tick cost of a resize, as a distribution.
  ///
  /// Side effect worth knowing: the "old path" measurement calls
  /// `PanelSize.set`, so running this **leaves the panel size wherever the last
  /// sample landed**. Reset with `defaults delete com.hermosalabs.pier
  /// panelWidth panelHeight`, or double-click the corner grip.
  ///
  /// Averages were useless here — three consecutive runs reported 3ms, 11ms and
  /// 12ms on the same build, because this machine is busy. Per-tick min/median
  /// /p90 over a warmed-up run is the honest signal, and the median is what a
  /// drag actually feels like.
  func resizePerfReport() -> String {
    func measure(_ label: String, warmup: Int = 10, ticks: Int = 60, body: (Int) -> Void)
      -> String
    {
      for i in 0..<warmup { body(i) }
      var samples: [Double] = []
      samples.reserveCapacity(ticks)
      for i in 0..<ticks {
        let start = Date()
        body(i)
        RunLoop.current.run(until: Date())
        samples.append(Date().timeIntervalSince(start) * 1000)
      }
      samples.sort()
      let median = samples[samples.count / 2]
      let p90 = samples[Int(Double(samples.count) * 0.9)]
      return String(
        format: "  %@: min %.2f · median %.2f · p90 %.2f ms", label, samples[0], median, p90)
    }

    var frame = panel.frame
    func resize(_ i: Int, display: Bool) {
      frame.size = NSSize(width: 420 + Double(i % 40), height: 540 + Double(i % 40))
      frame.origin.y = panel.frame.maxY - frame.height
      panel.setFrame(frame, display: display)
    }

    let live = measure("drag tick (window resize, SwiftUI relayout)") { resize($0, display: false) }
    let sync = measure("same, forcing synchronous redraw") { resize($0, display: true) }
    let persist = measure("old path (persist every tick)") { i in
      PanelSize.set(NSSize(width: 420 + Double(i % 40), height: 540 + Double(i % 40)))
    }
    let host = panel.contentView
    panel.contentView = NSView()
    let bare = measure("bare window, no SwiftUI content") { resize($0, display: false) }
    panel.contentView = host

    return """
      per drag tick — 60 samples after warmup, 16.7ms is the 60fps budget
      \(live)
      \(sync)
      \(persist)
      \(bare)
      """
  }

  /// Debug: the panel must stay exactly where it opened. This replaced a probe
  /// that asserted the opposite — that the panel re-anchored itself after the
  /// menu bar hid. Chasing the bar was the bug, so the assertion inverted.
  func panelStabilityReport() -> String {
    let opened = panel.frame
    // Long enough to have covered several ticks of the old 0.5s follow timer,
    // and to span a bar hide/reveal if the pointer crosses the top edge.
    RunLoop.current.run(until: Date().addingTimeInterval(2.5))
    let after = panel.frame
    let stable = opened == after
    let report = """
      opened at: \(rect(opened))
      2.5s later: \(rect(after))
      stable: \(stable)\(stable ? "" : "  ← the panel moved on its own")
      """
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(stable ? 0 : 1) }
    return report
  }

  /// Debug: apply a resize the way the grip does, and report what the window did.
  func resizeReport() -> String {
    let before = panel.frame
    let target = PanelSize.dragged(
      from: PanelSize.current,
      startMouse: NSPoint(x: 1000, y: 800),
      currentMouse: NSPoint(x: 1120, y: 720))  // +120 wide, +80 tall
    PanelSize.set(target)
    // The notification is delivered on the main run loop; let it land.
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let after = panel.frame
    let widthDelta = after.width - before.width
    let heightDelta = after.height - before.height
    let topDrift = after.maxY - before.maxY
    return """
      before: \(rect(before))
      target: \(Int(target.width))×\(Int(target.height))
      after:  \(rect(after))
      delta:  width \(String(format: "%+.0f", widthDelta)) · height \(String(format: "%+.0f", heightDelta))
      window followed: \(after.size == target)
      top edge planted: \(abs(topDrift) < 1) (drift \(String(format: "%+.0f", topDrift))pt)
      """
  }

  /// Debug: where the button and panel actually landed, so anchoring can be
  /// checked without eyeballing the menu bar (`--probe-anchor`).
  func anchorReport() -> String {
    guard let button = buttonScreenRect() else { return "no status button (menu bar full?)" }
    let p = panel.frame
    let computed = anchoredFrame()
    let screen = buttonScreen()
    let contained = screen.map { $0.visibleFrame.contains(p) } ?? false
    return """
      button:  \(rect(button))
      panel:   \(rect(p))  visible=\(panel.isVisible)
      computed: \(rect(computed))\(computed.origin == p.origin ? "" : "  ← window differs!")
      constrained: \(rect(panel.constrainFrameRect(computed, to: panel.screen)))
      button at open: \(rect(lastAnchorRect)) \
      \(lastAnchorRect.minX == button.minX ? "(unchanged)" : "← the item moved since opening")
      aligned: left edges \(String(format: "%+.0f", p.minX - button.minX))pt \
      · gap below button \(String(format: "%.0f", button.minY - p.maxY))pt
      screen:  \(screen.map { "frame \(rect($0.frame)) visible \(rect($0.visibleFrame))" } ?? "none")
      fullyOnScreen: \(contained)
      allScreens: \(NSScreen.screens.map { rect($0.frame) }.joined(separator: " | "))
      """
  }

  /// Height the menu bar currently reserves on the item's display, or nil when
  /// it reserves nothing (hidden, or another app's fullscreen space).
  private func menuBarReservedHeight() -> CGFloat? {
    guard let screen = buttonScreen() else { return nil }
    let reserved = screen.frame.maxY - screen.visibleFrame.maxY
    return reserved > 1 ? reserved : nil
  }

  private func rect(_ r: NSRect) -> String {
    "x\(Int(r.minX)) y\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var menuBar: MenuBarController?
  /// Held for the app's lifetime. Without it, macOS 26 App-Naps a windowless
  /// LSUIElement app and **drops its menu bar item** while the process keeps
  /// running — the icon just disappears. `.userInitiatedAllowingIdleSystemSleep`
  /// blocks App Nap plus automatic and sudden termination while still letting
  /// the system idle-sleep. (See docs/research/codexbar-practices.md #6.)
  private var keepAliveActivity: NSObjectProtocol?

  func applicationWillTerminate(_ notification: Notification) {
    PierLog.shared.log("quit")
    PierLog.shared.flush()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    PierLog.shared.log(
      "launch — Pier \(Bundle.main.shortVersion) (\(ProcessInfo.processInfo.processIdentifier))")
    keepAliveActivity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Keep the Pier menu bar item presented")

    // LSUIElement keeps the bundled app out of the Dock; .accessory mirrors
    // that when running the bare executable during development.
    NSApp.setActivationPolicy(.accessory)

    // Must run before the status item is constructed: clearing a corrupt saved
    // position after the fact doesn't move an item that's already placed.
    let repaired = StatusItemRepair.repairDefaults()
    if !repaired.isEmpty {
      PierLog.shared.log("status item defaults repaired: \(repaired.joined(separator: ", "))")
    }

    let controller = MenuBarController()
    menuBar = controller

    if CommandLine.arguments.contains("--probe-resize-perf") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        controller.simulateClick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          print(controller.resizePerfReport())
          exit(0)
        }
      }
    }

    // Debug: --probe-panel-stable opens the panel and checks it doesn't move
    // on its own — the menu bar hiding must no longer drag it around.
    if CommandLine.arguments.contains("--probe-panel-stable") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        controller.simulateClick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          print(controller.panelStabilityReport())
        }
      }
    }

    // Debug: --probe-resize drives the same call the resize grip makes and
    // reports whether the window actually followed (and kept its top edge).
    if CommandLine.arguments.contains("--probe-resize") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        controller.simulateClick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          print(controller.resizeReport())
          exit(0)
        }
      }
    }

    // Debug: --probe-anchor clicks the item, reports placement, exits.
    if CommandLine.arguments.contains("--probe-anchor") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        controller.simulateClick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          print(controller.anchorReport())
          exit(0)
        }
      }
    }
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  /// Opening Pier again — Spotlight, Finder, `open` — shows the panel. It's
  /// the way in when the menu bar icon can't be clicked: hidden by a crowded
  /// bar, behind the notch, or in a fullscreen space.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    PierLog.shared.log("reopened — showing the panel")
    menuBar?.showPanelIfHidden()
    return false
  }
}
