import AppKit
import SwiftUI

/// `--render-fixture-dev <dir>`: dev servers named by framework and project,
/// among the noise they're picked out of — in the All scope and the Dev scope,
/// at the 340pt minimum and the 440pt default. Kept out of `FixtureData` so
/// the existing renders stay byte-identical.
enum DevFixture {
  static func port(
    _ pid: Int32, _ port: Int, _ name: String, _ attribution: Attribution,
    dev: DevServer? = nil, cpu: Double = 0.4
  ) -> PortEntry {
    var entry = PortEntry(
      pid: pid, port: port, proto: .tcp, processName: name, user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: attribution,
      usage: Usage(cpu: cpu, rssKB: 140 * 1024))
    entry.dev = dev
    return entry
  }

  static let entries: [PortEntry] = [
    port(
      11_632, 4200, "node", .harness("Claude Code"),
      dev: DevServer(framework: "Angular", project: "storefront"), cpu: 3.2),
    port(
      23_832, 8782, "workerd", .harness("Claude Code"),
      dev: DevServer(framework: "Wrangler", project: "api (lanes/b)")),
    port(
      52_425, 8786, "workerd", .harness("Codex"),
      dev: DevServer(framework: "Wrangler", project: "api (lanes/f)")),
    port(
      37_707, 4173, "node", .none, dev: DevServer(framework: "Node", project: "planner")),
    port(
      41_010, 5173, "node",
      .terminal(TerminalSession(app: .ghostty, directory: "~/code/site", tty: "ttys005")),
      dev: DevServer(framework: "Vite", project: "site"), cpu: 6.1),
    // The noise the classifier rules out.
    port(56_112, 56_112, "Google Chrome for Testing", .harness("Claude Code")),
    port(56_202, 56_202, "Google Chrome for Testing", .harness("Claude Code")),
    port(23_832, 9229, "workerd", .harness("Claude Code")),
    port(94_156, 54_297, "claude", .harness("Claude Code")),
    port(965, 3025, "node", .harness("Cursor")),
  ]

  @MainActor
  static func render(to dir: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for scope in ["all", "dev"] {
      FixtureDefaults.apply(scope: scope)
      for width in [PanelSize.minWidth, PanelSize.defaultWidth] {
        let monitor = PortMonitor(fixture: entries, activity: [], history: FixtureData.history)
        let path = "\(dir)/dev-\(scope)-\(Int(width)).png"
        let view = PortListView().environmentObject(monitor)
        guard
          MemoryProbe.write(
            view, size: NSSize(width: width, height: PortListView.panelHeight), to: path)
        else {
          FileHandle.standardError.write("render-fixture-dev: failed \(path)\n".data(using: .utf8)!)
          exit(1)
        }
        print("wrote \(path)")
      }
    }
    exit(0)
  }
}
