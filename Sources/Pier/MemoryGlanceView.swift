import SwiftUI

/// The footer's RAM-vs-swap glance: a thin bar plus "27.6/32 GB · swap 0".
///
/// This is the **only** view that observes `MemoryMonitor`. `PortListView`
/// holds the monitor through the environment without observing it, so a tick
/// redraws this footer view and nothing else — not the panel's grouping, sort,
/// or rows.
struct MemoryGlanceView: View {
  @ObservedObject var monitor: MemoryMonitor

  /// Fixed rather than measured: a GeometryReader in the footer would cost a
  /// layout pass per tick for a bar that never changes width.
  static let barWidth: CGFloat = 40

  var body: some View {
    if let snapshot = monitor.snapshot {
      HStack(spacing: 5) {
        MemoryBar(snapshot: snapshot)
          .frame(width: Self.barWidth, height: 6)
        Text(MemoryFormat.glance(snapshot))
          .monospacedDigit()
        if snapshot.isPaging {
          // Only while pages are actually being written out — the state that
          // costs you, unlike swap that's merely still allocated.
          Image(systemName: "arrow.down.to.line")
            .foregroundStyle(.orange)
        }
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .fixedSize()
      .help(MemoryFormat.tooltip(snapshot))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(MemoryFormat.tooltip(snapshot))
    }
  }
}

/// App / wired / compressed as segments of one bar, in the pressure colour.
/// The *colour* carries the verdict and the *length* carries the share, so a
/// full-looking bar in green reads as "busy and fine" — which is what a Mac
/// using its RAM properly looks like.
private struct MemoryBar: View {
  let snapshot: MemorySnapshot

  var body: some View {
    let total = max(Double(snapshot.total), 1)
    let width = MemoryGlanceView.barWidth
    let tint = snapshot.pressure.tint
    ZStack(alignment: .leading) {
      Capsule().fill(Color.secondary.opacity(0.18))
      HStack(spacing: 0) {
        Rectangle().fill(tint.opacity(0.9))
          .frame(width: width * Double(snapshot.app) / total)
        Rectangle().fill(tint.opacity(0.6))
          .frame(width: width * Double(snapshot.wired) / total)
        // Compressed gets its own visible segment: macOS compresses long before
        // it swaps, so on a busy machine this — not swap — is where the
        // pressure actually shows up first.
        Rectangle().fill(tint.opacity(0.32))
          .frame(width: width * Double(snapshot.compressed) / total)
      }
      .clipShape(Capsule())
    }
  }
}

extension MemoryFormat {
  /// The footer text. "swap", lower-case and in bytes: the macOS term (not
  /// "page file"), and never a ratio — the swap total is 0 until macOS needs it.
  static func glance(_ s: MemorySnapshot) -> String {
    "\(gigabytes(s.used))/\(totalGigabytes(s.total)) GB · swap \(swap(s.swapUsed))"
  }

  /// Activity Monitor's vocabulary, so the numbers can be checked against it.
  static func tooltip(_ s: MemorySnapshot) -> String {
    var lines = [
      "Memory pressure: \(s.pressure.label)",
      "Used \(gigabytes(s.used)) GB of \(totalGigabytes(s.total)) GB",
      "  App \(gigabytes(s.app)) GB · Wired \(gigabytes(s.wired)) GB · Compressed \(gigabytes(s.compressed)) GB",
      "Cached files \(gigabytes(s.cached)) GB",
      "Swap used \(swap(s.swapUsed))",
    ]
    if let rate = s.swapoutsPerSecond, rate > 0 {
      lines.append(String(format: "Paging out: %.0f pages/s", rate))
    }
    return lines.joined(separator: "\n")
  }
}

/// Startup-disk free space, sitting right after the memory glance in the same
/// footer row. Its own view with its own layout priority, so as the panel
/// narrows the footer gives way in a deliberate order: "Updated" goes first,
/// then this, and the memory glance never does — no wrapping, no extra height.
struct DiskGlanceView: View {
  @ObservedObject var monitor: MemoryMonitor

  var body: some View {
    if let disk = monitor.disk {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 3) {
          Image(systemName: "internaldrive")
          Text("\(DiskSpace.format(disk.free)) free")
            .monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(MemoryFormat.diskTooltip(disk))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MemoryFormat.diskTooltip(disk))
        // Too narrow: drop out entirely rather than truncate to "89 G…".
        Color.clear.frame(width: 0, height: 0)
      }
    }
  }
}

extension MemoryFormat {
  /// Finder's figure appears alongside, so Pier never looks like it disagrees
  /// with Finder about how much space there is.
  static func diskTooltip(_ d: DiskSnapshot) -> String {
    var lines = ["Startup disk: \(DiskSpace.format(d.free)) free of \(DiskSpace.format(d.total))"]
    if let available = d.availableIncludingPurgeable, available > d.free {
      lines.append("\(DiskSpace.format(available)) available incl. purgeable (Finder's figure)")
    }
    return lines.joined(separator: "\n")
  }
}
