import AppKit

/// `--render-fixture-statusitem <dir>`: the menu bar item's glyph and title in
/// light and dark mode, for normal / Warning / Critical pressure with and
/// without the unseen-events bullet. Drawn by a plain borderless `NSButton` —
/// the status item's own button can't be rasterised outside the menu bar — on
/// the two menu bar backgrounds, so contrast is checkable in both modes.
enum StatusItemFixture {
  static let cases: [(MemoryPressure, Int)] = [
    (.normal, 0), (.normal, 3), (.warning, 0), (.critical, 2),
  ]

  @MainActor
  static func render(to dir: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let icon = Bundle.module.image(forResource: "menubar-icon")
    icon?.isTemplate = true
    icon?.size = NSSize(width: 16, height: 16)

    for (name, appearance, background) in [
      ("light", NSAppearance.Name.aqua, NSColor(white: 0.93, alpha: 1)),
      ("dark", NSAppearance.Name.darkAqua, NSColor(white: 0.13, alpha: 1)),
    ] {
      let row = NSSize(width: 90, height: 24)
      let root = NSView(
        frame: NSRect(x: 0, y: 0, width: row.width, height: row.height * CGFloat(cases.count)))
      root.appearance = NSAppearance(named: appearance)
      root.wantsLayer = true
      root.layer?.backgroundColor = background.cgColor
      for (i, (pressure, unseen)) in cases.enumerated() {
        let button = NSButton(
          frame: NSRect(
            x: 4, y: root.bounds.height - row.height * CGFloat(i + 1), width: row.width - 8,
            height: row.height))
        button.isBordered = false
        button.image = icon
        button.imagePosition = .imageLeading
        let title = StatusTitle.make(unseen: unseen, pressure: pressure)
        button.attributedTitle = title
        button.imagePosition = title.length == 0 ? .imageOnly : .imageLeading
        root.addSubview(button)
      }
      let window = NSWindow(
        contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = root
      window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
      window.orderBack(nil)
      root.layoutSubtreeIfNeeded()
      guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { exit(1) }
      root.cacheDisplay(in: root.bounds, to: rep)
      let path = "\(dir)/statusitem-\(name).png"
      guard let png = rep.representation(using: .png, properties: [:]),
        (try? png.write(to: URL(fileURLWithPath: path))) != nil
      else {
        FileHandle.standardError.write(
          "render-fixture-statusitem: failed \(path)\n".data(using: .utf8)!)
        exit(1)
      }
      print("wrote \(path)")
    }
    exit(0)
  }
}
