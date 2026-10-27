import AppKit
import SwiftUI

/// Probes for the memory glance, per the repo rule that every subsystem gets one.
enum MemoryProbe {
  /// `--print-memory`: one live reading, in the same words the glance and its
  /// tooltip use, so the numbers can be checked against Activity Monitor or
  /// `vm_stat`. Two samples a second apart, so the paging rate has a baseline.
  @MainActor
  static func printMemory() {
    let monitor = MemoryMonitor()
    monitor.sample()
    Thread.sleep(forTimeInterval: 1)
    monitor.sample()
    guard let s = monitor.snapshot else {
      print("host_statistics64 failed — no reading")
      return
    }
    print("glance:  \(MemoryFormat.glance(s))")
    print(MemoryFormat.tooltip(s).split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
    print("page size: \(KernelPage.size) bytes (vm_stat reports the same unit)")
    print(
      "menu bar count colour: \(monitor.pressure.tintName) (\(monitor.pressure.label) pressure)")
    print("thermal: \(monitor.thermal.label) — \(monitor.thermal.explanation)")
    if let cpu = monitor.cpu { print("cpu:     \(CPULoad.format(cpu)) of all cores") }
    let table = ProcessTable.parse(
      ProcessRunner.run("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,rss=,ucomm="], timeout: 5)?.stdout
        ?? "")
    print("busiest: \(table.busiest().map(\.label).joined(separator: ", "))")
    if let disk = DiskSpace.read() {
      print("disk:    \(DiskSpace.format(disk.free)) free")
      print(
        MemoryFormat.diskTooltip(disk).split(separator: "\n").map { "  \($0)" }.joined(
          separator: "\n"))
    }
  }

  /// Three states worth grading: a healthy busy Mac (this dev machine's real
  /// shape — heavy compression, no swap), pressure building, and critical with
  /// pages actively going out.
  /// Heat to pair with each memory state, so the footer is graded with the
  /// CPU glance in every state it can show: cool, Hot (throttling), Very hot.
  static let heat: [String: (thermal: ThermalLevel, cpu: Double)] = [
    "normal": (.nominal, 0.22), "warning": (.serious, 0.78), "critical": (.critical, 0.96),
  ]

  static let fixtures: [(name: String, snapshot: MemorySnapshot)] = {
    func gb(_ x: Double) -> UInt64 { UInt64(x * MemoryFormat.gigabyte) }
    return [
      (
        "normal",
        MemorySnapshot(
          total: gb(32), app: gb(13.0), wired: gb(3.1), compressed: gb(11.5), cached: gb(3.7),
          swapUsed: 0, swapTotal: 0, pressure: .normal, swapoutsPerSecond: 0)
      ),
      (
        "warning",
        MemorySnapshot(
          total: gb(32), app: gb(18.2), wired: gb(4.0), compressed: gb(8.1), cached: gb(0.9),
          swapUsed: gb(2.3), swapTotal: gb(3), pressure: .warning, swapoutsPerSecond: 0)
      ),
      (
        "critical",
        MemorySnapshot(
          total: gb(32), app: gb(20.4), wired: gb(5.0), compressed: gb(6.0), cached: gb(0.3),
          swapUsed: gb(6.8), swapTotal: gb(8), pressure: .critical, swapoutsPerSecond: 340)
      ),
    ]
  }()

  /// This machine's real shape: ~89 GB free of 494 GB, Finder showing ~92.
  static let fixtureDisk = DiskSnapshot(
    free: 88_700_000_000, total: 494_400_000_000, availableIncludingPurgeable: 91_900_000_000)

  /// `--render-fixture-memory <dir>`: the **full panel**, not the glance alone,
  /// at the 340pt minimum and the 440pt default. A glance rendered in isolation
  /// can't show the footer overflowing — the same failure as the chip row (trap
  /// #17), which only `--render-fixture-narrow` caught.
  @MainActor
  static func renderFixtures(to dir: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    FixtureDefaults.apply(scope: "all")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    for (name, snapshot) in fixtures {
      for width in [PanelSize.minWidth, PanelSize.defaultWidth] {
        let monitor = PortMonitor(
          fixture: Array(FixtureData.entries.prefix(4)), activity: FixtureData.activity,
          history: FixtureData.history)
        let view = PortListView()
          .environmentObject(monitor)
          .environment(
            \.memoryMonitor,
            MemoryMonitor(
              fixed: snapshot, disk: fixtureDisk, thermal: heat[name]?.thermal ?? .nominal,
              cpu: heat[name]?.cpu))
        let path = "\(dir)/memory-\(name)-\(Int(width)).png"
        guard write(view, size: NSSize(width: width, height: PortListView.panelHeight), to: path)
        else {
          FileHandle.standardError.write(
            "render-fixture-memory: failed \(path)\n".data(using: .utf8)!)
          exit(1)
        }
        print("wrote \(path)")
      }
    }
    exit(0)
  }

  @MainActor
  static func write<V: View>(_ view: V, size: NSSize, to path: String) -> Bool {
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderBack(nil)
    hosting.layoutSubtreeIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      return false
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }
}
