import AppKit
import SwiftUI

/// `--render-fixture-terminals <dir>`: ports in two Ghostty tabs and a
/// Terminal tab beside an agent group, at the 340pt minimum and the 440pt
/// default. Kept out of `FixtureData` so the existing renders stay
/// byte-identical.
enum TerminalFixture {
  static func port(
    _ pid: Int32, _ port: Int, _ name: String, _ session: TerminalSession,
    cpu: Double = 0.4, rssMB: Int = 90
  ) -> PortEntry {
    PortEntry(
      pid: pid, port: port, proto: .tcp, processName: name, user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .terminal(session),
      usage: Usage(cpu: cpu, rssKB: rssMB * 1024))
  }

  static let entries: [PortEntry] =
    Array(FixtureData.entries.prefix(2)) + [
      port(
        41_010, 5173, "node",
        TerminalSession(app: .ghostty, directory: "~/code/web", tty: "ttys005"),
        cpu: 6.1, rssMB: 210),
      port(
        41_020, 8000, "Python",
        TerminalSession(app: .ghostty, directory: "~/code/api", tty: "ttys006")),
      port(
        41_030, 4000, "ruby",
        TerminalSession(app: .terminal, directory: "~/code/docs", tty: "ttys007")),
    ]

  @MainActor
  static func render(to dir: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    FixtureDefaults.apply(scope: "all")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for width in [PanelSize.minWidth, PanelSize.defaultWidth] {
      let monitor = PortMonitor(fixture: entries, activity: [], history: FixtureData.history)
      let path = "\(dir)/terminals-\(Int(width)).png"
      let view = PortListView().environmentObject(monitor)
      guard
        MemoryProbe.write(
          view, size: NSSize(width: width, height: PortListView.panelHeight), to: path)
      else {
        FileHandle.standardError.write(
          "render-fixture-terminals: failed \(path)\n".data(using: .utf8)!)
        exit(1)
      }
      print("wrote \(path)")
    }
    exit(0)
  }
}
