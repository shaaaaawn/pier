import AppKit
import Foundation

// "Is my Mac hot, and who's doing it?"
//
// "Hot" — the menu bar dot, the colour — is `ProcessInfo.thermalState`: the
// state macOS itself throttles on, published with a change notification,
// readable without any permission. Temperatures in °C and fan speeds are a
// separate, descriptive reading (`SMC.swift`): public IOKit calls, but
// undocumented sensor keys that vary by chip, so they inform the footer and
// never decide whether the Mac counts as hot. CPU load (host tick counters,
// ~µs) and the busiest processes (from the `ps` table Pier already reads)
// answer "who's doing it".

/// macOS's thermal state, in the order it escalates.
enum ThermalLevel: Int, Comparable, Sendable {
  case nominal, fair, serious, critical

  init(_ state: ProcessInfo.ThermalState) {
    switch state {
    case .nominal: self = .nominal
    case .fair: self = .fair
    case .serious: self = .serious
    case .critical: self = .critical
    @unknown default: self = .serious
    }
  }

  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

  var label: String {
    switch self {
    case .nominal: return "Normal"
    case .fair: return "Warm"
    case .serious: return "Hot"
    case .critical: return "Very hot"
    }
  }

  /// What it means for you, in the tooltip.
  var explanation: String {
    switch self {
    case .nominal: return "running cool"
    case .fair: return "fans may spin up; no slowdown yet"
    case .serious: return "macOS is slowing the CPU to cool down"
    case .critical: return "macOS is slowing the CPU hard"
    }
  }

  /// Serious and up is "hot" for the menu bar mark. Fair is routine under any
  /// real build and would light the dot all day.
  var isHot: Bool { self >= .serious }

  /// The same adaptive orange / red as memory pressure, so one dot means one
  /// thing: the Mac is under strain.
  var asStrain: MemoryPressure {
    switch self {
    case .nominal, .fair: return .normal
    case .serious: return .warning
    case .critical: return .critical
    }
  }

  static var current: ThermalLevel { ThermalLevel(ProcessInfo.processInfo.thermalState) }
}

/// Cumulative CPU ticks across all cores, from `HOST_CPU_LOAD_INFO`.
struct CPUTicks: Equatable, Sendable {
  var user: UInt64
  var system: UInt64
  var idle: UInt64
  var nice: UInt64

  var busy: UInt64 { user + system + nice }
  var total: UInt64 { busy + idle }
}

enum CPULoad {
  /// Fraction of all cores busy between two readings (0…1). nil without a
  /// previous reading, or if the counters went backwards.
  static func usage(previous: CPUTicks?, current: CPUTicks) -> Double? {
    guard let previous, current.total > previous.total, current.busy >= previous.busy
    else { return nil }
    return Double(current.busy - previous.busy) / Double(current.total - previous.total)
  }

  static func read(host: mach_port_t) -> CPUTicks? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let t = info.cpu_ticks
    return CPUTicks(
      user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
  }

  /// "34%" of the whole machine.
  static func format(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
  }
}

/// One line of "who's making it hot".
struct BusyProcess: Equatable, Sendable {
  let name: String
  /// Percent of one core, summed over every process with this name — forty
  /// "Google Chrome Helper" processes are one culprit, not forty small ones.
  let cpu: Double
  let count: Int

  var label: String {
    let times = count > 1 ? " ×\(count)" : ""
    return "\(name)\(times) \(Int(cpu.rounded()))%"
  }
}

extension ProcessTable {
  /// The heaviest CPU users by name. Anything under 1% of a core is idle
  /// noise, not an answer.
  func busiest(limit: Int = 3) -> [BusyProcess] {
    var cpu: [String: Double] = [:]
    var count: [String: Int] = [:]
    for proc in byPid.values where proc.cpu > 0 {
      cpu[proc.name, default: 0] += proc.cpu
      count[proc.name, default: 0] += 1
    }
    return
      cpu
      .filter { $0.value >= 1 }
      .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
      .prefix(limit)
      .map { BusyProcess(name: $0.key, cpu: $0.value, count: count[$0.key] ?? 1) }
  }
}
