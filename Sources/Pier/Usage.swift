import CoreGraphics
import Foundation

/// One process's live resource use, sampled each refresh.
struct Usage: Equatable {
  /// Percent of one core (`ps` semantics — can exceed 100 on multicore).
  let cpu: Double
  let rssKB: Int

  var memoryLabel: String {
    let mb = Double(rssKB) / 1024
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    if mb >= 100 { return String(format: "%.0f MB", mb) }
    return String(format: "%.1f MB", mb)
  }

  /// Compact CPU label: sub-1% collapses to "<1%" rather than "0.4%" noise.
  var cpuLabel: String {
    if cpu >= 10 { return String(format: "%.0f%%", cpu) }
    if cpu >= 1 { return String(format: "%.1f%%", cpu) }
    return cpu > 0 ? "<1%" : "0%"
  }
}

/// Rolling per-pid CPU history behind the row sparklines.
///
/// Kept deliberately small: a fixed window of recent samples, pruned to the
/// pids that still exist so a machine that churns dev servers all day doesn't
/// accumulate history for thousands of dead processes.
struct UsageHistory: Equatable {
  /// Samples retained per pid (~2 min at the 5s visible cadence).
  static let window = 24

  private(set) var samples: [Int32: [Double]] = [:]

  /// Append this round's CPU readings and drop pids that are gone.
  mutating func record(_ readings: [Int32: Double]) {
    for (pid, cpu) in readings {
      var series = samples[pid] ?? []
      series.append(cpu)
      if series.count > Self.window { series.removeFirst(series.count - Self.window) }
      samples[pid] = series
    }
    samples = samples.filter { readings.keys.contains($0.key) }
  }

  func series(for pid: Int32) -> [Double] { samples[pid] ?? [] }
}

/// Shapes a CPU series into bar heights for the row sparkline.
enum Sparkline {
  /// Bars drawn per row.
  static let bars = 14
  /// Floor so an idle process still shows a baseline instead of nothing.
  static let minFraction: CGFloat = 0.08

  /// Normalized bar heights (0…1), oldest → newest, right-aligned to `bars`.
  ///
  /// Scaled against the series' own peak with a 5% floor, so a process idling
  /// at 0.2% doesn't render as a full-height bar — the sparkline shows *this
  /// process's* shape, and the adjacent number carries the absolute value.
  static func heights(_ series: [Double], bars: Int = bars) -> [CGFloat] {
    guard bars > 0 else { return [] }
    let recent = Array(series.suffix(bars))
    guard !recent.isEmpty else { return [] }
    let peak = max(recent.max() ?? 0, 5)
    let scaled = recent.map { value -> CGFloat in
      let fraction = CGFloat(max(0, value) / peak)
      return max(minFraction, min(1, fraction))
    }
    // Right-align: a young series grows in from the right edge.
    return scaled
  }

  /// True when there's enough history for the shape to mean anything.
  static func isMeaningful(_ series: [Double]) -> Bool { series.count >= 2 }
}
