import AppKit
import Darwin
import Foundation
import SwiftUI

// RAM vs swap at a glance, read the way Activity Monitor reads it.
//
// Every choice below came from reading how the established monitors do this
// (Stats, MenuMeters, eul) and then checking it on a real machine:
//
// - **In-process, no spawns.** One `host_statistics64(HOST_VM_INFO64)` call plus
//   two sysctls costs ~3 µs. Stats and MenuMeters both work this way; eul shells
//   out to `top`/`vm_stat`, which is the pattern to avoid. For scale, one port
//   refresh spawns `lsof`/`ps` for ~250 ms of CPU — memory is effectively free.
// - **The host port is fetched once.** `mach_host_self()` adds a send-right
//   reference on every call; measured uncached, 1,000 samples took the count
//   from 2 to 1,002. At one sample every 2 s that leaks ~43k references a day.
// - **Activity Monitor's definition of "Memory Used":** App (internal −
//   purgeable) + Wired + Compressed. Stats sums the page queues instead
//   (active + inactive + speculative + wired + compressed − purgeable −
//   external) and gets the same 27.58 GB on the dev machine; this form says
//   what it means.
// - **Kernel pages.** The counts are in `vm_kernel_page_size`, which only
//   differs from `vm_page_size` under Rosetta — exactly when using the wrong one
//   would quietly scale every number by 4×. Read through `KernelPage.size`:
//   Swift 6 treats the C global itself as shared mutable state.

/// The unit `host_statistics64` counts in. `host_page_size` returns
/// `vm_kernel_page_size` — measured 16 KB both native and under Rosetta, where
/// `vm_page_size` and `getpagesize()` drop to 4 KB — through a call, so Swift 6
/// doesn't have to treat a C global as shared mutable state.
enum KernelPage {
  static let size: UInt64 = {
    // Released here: each mach_host_self() adds a send-right (see above).
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var size: vm_size_t = 0
    guard host_page_size(host, &size) == KERN_SUCCESS, size > 0 else { return 16_384 }
    return UInt64(size)
  }()
}

/// Activity Monitor's green / yellow / red. Driven by the kernel's own verdict
/// (`kern.memorystatus_vm_pressure_level`), **not** by percent used: Apple's
/// guidance is that high Memory Used is normal, and a bar that turned red at
/// 86% would be red most of the day on a healthy Mac.
enum MemoryPressure: Int, Equatable {
  case normal = 1
  case warning = 2
  case critical = 4

  /// Unknown levels read as normal rather than alarming.
  init(sysctlLevel: Int32) {
    self = MemoryPressure(rawValue: Int(sysctlLevel)) ?? .normal
  }

  var label: String {
    switch self {
    case .normal: return "Normal"
    case .warning: return "Warning"
    case .critical: return "Critical"
    }
  }

  /// The menu bar icon's tint. **nil at normal**, so the template image keeps
  /// inverting with the menu bar the way every other item does; colour appears
  /// only when the kernel says memory is under pressure. Same yellow/red as
  /// Activity Monitor and the footer glance, so the two never disagree.
  var statusTint: NSColor? {
    switch self {
    case .normal: return nil
    case .warning: return .systemYellow
    case .critical: return .systemRed
    }
  }

  /// For probes and logs.
  var tintName: String {
    switch self {
    case .normal: return "none"
    case .warning: return "yellow"
    case .critical: return "red"
    }
  }

  var tint: Color {
    switch self {
    case .normal: return .green
    case .warning: return .yellow
    case .critical: return .red
    }
  }
}

/// Raw page counts from `vm_statistics64`, kept separate so the arithmetic is
/// testable without a kernel.
struct VMCounters: Equatable {
  var internalPages: UInt64
  var purgeablePages: UInt64
  var wiredPages: UInt64
  var compressedPages: UInt64
  var externalPages: UInt64
  /// Cumulative since boot — only its rate of change means anything.
  var swapouts: UInt64
}

struct MemorySnapshot: Equatable {
  var total: UInt64
  var app: UInt64
  var wired: UInt64
  var compressed: UInt64
  /// File-backed pages the system can drop instantly. Not part of "used".
  var cached: UInt64
  var swapUsed: UInt64
  var swapTotal: UInt64
  var pressure: MemoryPressure
  /// Pages written to swap per second since the previous sample. nil until
  /// there is a baseline to measure against.
  var swapoutsPerSecond: Double?

  var used: UInt64 { app + wired + compressed }

  /// Paging *right now* is what hurts; swap *used* can sit high for hours after
  /// the pressure that caused it has gone.
  var isPaging: Bool { (swapoutsPerSecond ?? 0) > 0 }

  /// Everything the glance or its tooltip shows, at the precision it shows it.
  /// Publishing only when this changes keeps a steady machine from redrawing
  /// anything at all.
  var displayKey: [Int] {
    let tenthGB = { (b: UInt64) in Int((Double(b) / MemoryFormat.gigabyte * 10).rounded()) }
    return [
      tenthGB(total), tenthGB(app), tenthGB(wired), tenthGB(compressed), tenthGB(cached),
      Int((Double(swapUsed) / MemoryFormat.megabyte).rounded()), pressure.rawValue,
      Int((swapoutsPerSecond ?? -1).rounded()),
    ]
  }
}

enum MemoryMath {
  static func snapshot(
    counters c: VMCounters, pageSize: UInt64, total: UInt64,
    swapUsed: UInt64, swapTotal: UInt64, pressureLevel: Int32, swapoutsPerSecond: Double?
  ) -> MemorySnapshot {
    // Purgeable pages are counted inside internal ones but can be discarded
    // without paging, so Activity Monitor leaves them out of App Memory. The
    // subtraction is clamped: the two counts are read in one call but are not
    // guaranteed consistent with each other.
    let appPages = c.internalPages > c.purgeablePages ? c.internalPages - c.purgeablePages : 0
    return MemorySnapshot(
      total: total,
      app: appPages * pageSize,
      wired: c.wiredPages * pageSize,
      compressed: c.compressedPages * pageSize,
      cached: (c.externalPages + c.purgeablePages) * pageSize,
      swapUsed: swapUsed,
      swapTotal: swapTotal,
      pressure: MemoryPressure(sysctlLevel: pressureLevel),
      swapoutsPerSecond: swapoutsPerSecond)
  }

  /// Rate between two cumulative readings. nil when there's no earlier
  /// reading, no time has passed, or the counter went backwards (a reset) —
  /// every one of those would otherwise produce a confident, wrong number.
  static func rate(
    previous: (count: UInt64, at: TimeInterval)?, current: (count: UInt64, at: TimeInterval)
  ) -> Double? {
    guard let previous, current.at > previous.at, current.count >= previous.count else {
      return nil
    }
    return Double(current.count - previous.count) / (current.at - previous.at)
  }
}

enum MemoryFormat {
  static let gigabyte = 1_073_741_824.0
  static let megabyte = 1_048_576.0

  /// "27.6" — one decimal, unit supplied by the caller.
  static func gigabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f", Double(bytes) / gigabyte)
  }

  /// Total RAM reads as a whole number when it is one ("32", not "32.0").
  static func totalGigabytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / gigabyte
    return gb.rounded() == gb ? String(Int(gb)) : String(format: "%.1f", gb)
  }

  /// Swap is shown in absolute bytes, never as used/total: macOS grows swap on
  /// demand, so the total is 0 until it's needed and a ratio would mean nothing.
  static func swap(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0" }
    let mb = Double(bytes) / megabyte
    return mb < 1024 ? String(format: "%.0f MB", mb) : String(format: "%.1f GB", mb / 1024)
  }
}

/// Samples memory while the panel is open and publishes only when something
/// the glance would draw has changed.
///
/// Deliberately its own object rather than more state on `PortMonitor`: only
/// `MemoryGlanceView` observes it, so a tick redraws one footer view instead of
/// recomputing the whole panel's grouping and rows.
@MainActor
final class MemoryMonitor: ObservableObject {
  @Published private(set) var snapshot: MemorySnapshot?
  /// Separate from `snapshot` so the menu bar item observes only this: a RAM
  /// tick must not redraw the status item, and pressure must stay current while
  /// the panel is closed and nothing is sampling.
  @Published private(set) var pressure: MemoryPressure = .normal
  /// Startup-volume free space. Disk changes slowly, so it's read on panel open
  /// and then once a minute — not on the 2 s memory tick.
  @Published private(set) var disk: DiskSnapshot?
  static let diskInterval: TimeInterval = 60
  private var lastDiskRead: TimeInterval?

  /// Two seconds: Activity Monitor's default refresh, and at ~3 µs per sample
  /// the interval is about legibility, not cost.
  static let interval: TimeInterval = 2

  private let host: mach_port_t
  private let isFixed: Bool
  private var timer: Timer?
  private var baseline: (count: UInt64, at: TimeInterval)?
  /// Kernel push notifications for pressure transitions — no polling. This is
  /// the one consumer that needs pressure while the panel is closed (the menu
  /// bar tint), which is why it exists at all.
  /// A `let`, set once, so the nonisolated deinit may cancel it.
  private let pressureSource: DispatchSourceMemoryPressure?

  init() {
    host = mach_host_self()
    isFixed = false
    // The source only reports *changes*, so read the current level once.
    pressure = Self.readPressure()
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    // Stored before the handler captures self: every property must be set first.
    pressureSource = source
    // Re-read the level rather than trusting the event's flags: the sysctl is
    // the same value the panel's own sampling uses, so the two can't disagree.
    // The source delivers on the main queue, so asserting isolation is safe.
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.updatePressure(Self.readPressure()) }
    }
    source.activate()
  }

  /// Fixture renders: a fixed value, never sampled, so PNGs stay reproducible.
  init(fixed: MemorySnapshot, disk: DiskSnapshot? = nil) {
    host = mach_host_self()
    isFixed = true
    snapshot = fixed
    pressure = fixed.pressure
    self.disk = disk
    pressureSource = nil
  }

  /// The timer can't be invalidated here: deinit is nonisolated and `timer` is
  /// main-actor state. Its block holds `self` weakly and invalidates itself on
  /// the first tick after we're gone.
  deinit {
    pressureSource?.cancel()
    mach_port_deallocate(mach_task_self_, host)
  }

  /// Sample only while someone can see it. Nothing runs while the panel is
  /// closed — not even the pressure sysctl.
  func setActive(_ active: Bool) {
    guard !isFixed else { return }
    timer?.invalidate()
    timer = nil
    guard active else { return }
    // A rate measured across the time the panel was closed would average the
    // whole gap into one meaningless number. Start over.
    baseline = nil
    lastDiskRead = nil
    sample()
    let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      // Scheduled on RunLoop.main below, so this block always fires on main.
      MainActor.assumeIsolated { self.sample() }
    }
    timer.tolerance = Self.interval * 0.25
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func sample() {
    guard let counters = readCounters() else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let current = (count: counters.swapouts, at: now)
    let rate = MemoryMath.rate(previous: baseline, current: current)
    baseline = current

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

    var level: Int32 = 0
    var levelSize = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

    let next = MemoryMath.snapshot(
      counters: counters, pageSize: KernelPage.size,
      total: ProcessInfo.processInfo.physicalMemory,
      swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
      pressureLevel: level, swapoutsPerSecond: rate)
    if snapshot?.displayKey != next.displayKey { snapshot = next }
    updatePressure(next.pressure)
    readDiskIfDue(now: now)
  }

  /// Off the main thread: Finder's "available" figure costs ~11.5 ms, and this
  /// runs from the panel's main-thread timer.
  private func readDiskIfDue(now: TimeInterval) {
    if let last = lastDiskRead, now - last < Self.diskInterval { return }
    lastDiskRead = now
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let reading = DiskSpace.read()
      DispatchQueue.main.async {
        guard let self, self.disk?.displayKey != reading?.displayKey else { return }
        self.disk = reading
      }
    }
  }

  /// Publishes only on a real change, so the menu bar isn't redrawn per sample.
  func updatePressure(_ level: MemoryPressure) {
    if pressure != level { pressure = level }
  }

  static func readPressure() -> MemoryPressure {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
    return MemoryPressure(sysctlLevel: level)
  }

  private func readCounters() -> VMCounters? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return VMCounters(
      internalPages: UInt64(stats.internal_page_count),
      purgeablePages: UInt64(stats.purgeable_count),
      wiredPages: UInt64(stats.wire_count),
      compressedPages: UInt64(stats.compressor_page_count),
      externalPages: UInt64(stats.external_page_count),
      swapouts: stats.swapouts)
  }
}

/// Optional, so a view tree that never injects one (every existing fixture
/// render) draws exactly what it drew before.
private struct MemoryMonitorKey: EnvironmentKey {
  static let defaultValue: MemoryMonitor? = nil
}

extension EnvironmentValues {
  var memoryMonitor: MemoryMonitor? {
    get { self[MemoryMonitorKey.self] }
    set { self[MemoryMonitorKey.self] = newValue }
  }
}
