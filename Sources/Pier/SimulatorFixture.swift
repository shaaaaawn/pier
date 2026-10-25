import AppKit
import SwiftUI

/// `--render-fixture-simulators <dir>`: the panel with two booted simulators
/// beside the container and MCP sections, at the 340pt minimum and the 440pt
/// default, so the section's header menu and rows are gradeable without
/// booting a device. Kept out of `FixtureData` so the existing renders stay
/// byte-identical.
enum SimulatorFixture {
  static let devices = "/Users/me/Library/Developer/CoreSimulator/Devices"

  static let activity: [ActivityEntry] =
    Array(FixtureData.activity.prefix(2)) + [
      ActivityEntry(
        kind: .simulator, name: "iPhone 17 Pro", detail: "iOS 26.5", pids: [41_200],
        usage: Usage(cpu: 4.2, rssKB: 3_900 * 1024),
        simulator: SimulatorRef(udid: "D68F26C2-3570-40C5-A84D-7FF5D6312381", deviceSet: devices)),
      ActivityEntry(
        kind: .simulator, name: "Apple TV 4K (3rd generation)", detail: "tvOS 27.0",
        pids: [41_350], usage: Usage(cpu: 2.7, rssKB: 4_100 * 1024),
        simulator: SimulatorRef(udid: "9EA9727F-73BE-434B-B741-0B574074688A", deviceSet: devices)),
    ] + FixtureData.activity.filter { $0.kind == .mcp }.prefix(1)

  @MainActor
  static func render(to dir: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    FixtureDefaults.apply(scope: "containers")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for width in [PanelSize.minWidth, PanelSize.defaultWidth] {
      let monitor = PortMonitor(
        fixture: Array(FixtureData.entries.prefix(2)), activity: activity,
        history: FixtureData.history)
      let path = "\(dir)/simulators-\(Int(width)).png"
      let view = PortListView().environmentObject(monitor)
      guard
        MemoryProbe.write(
          view, size: NSSize(width: width, height: PortListView.panelHeight), to: path)
      else {
        FileHandle.standardError.write(
          "render-fixture-simulators: failed \(path)\n".data(using: .utf8)!)
        exit(1)
      }
      print("wrote \(path)")
    }
    exit(0)
  }
}
