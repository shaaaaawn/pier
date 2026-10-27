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

/// The footer's heat glance: temperature and CPU, each as a value on a small
/// line — "current against its last-30-minutes low/high, on a fixed scale".
/// The line answers "is that a lot?" at a glance: CPU's track ends at 100%
/// (every core busy), temperature's runs 30–105 °C.
///
/// Observes `MemoryMonitor` like the other glances, so a tick redraws this
/// view alone. `busiest` comes from the panel's own refresh.
struct CPUGlanceView: View {
  @ObservedObject var monitor: MemoryMonitor
  let busiest: [BusyProcess]

  static let temperatureScale: ClosedRange<Double> = 30...105
  static let cpuScale: ClosedRange<Double> = 0...1

  var body: some View {
    if let cpu = monitor.cpu {
      let thermal = monitor.thermal
      let tooltip = MemoryFormat.heatTooltip(
        cpu: cpu, cpuRange: monitor.cpuRange, thermal: thermal,
        temperature: monitor.temperature, temperatureRange: monitor.temperatureRange,
        busiest: busiest)
      ViewThatFits(in: .horizontal) {
        label(cpu: cpu, thermal: thermal, lines: true)
        label(cpu: cpu, thermal: thermal, lines: false)
        // One number: the temperature if there is one, else CPU.
        HStack(spacing: 3) {
          Image(systemName: Self.symbol(thermal))
            .foregroundStyle(Self.tint(thermal))
          Text(
            monitor.temperature.map { TemperatureReading.format($0.cpuAverage) }
              ?? CPULoad.format(cpu)
          )
          .monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize()
        // Narrowest: the thermometer alone. Strain lengthens the memory text,
        // so this is exactly when the room runs out — and when the colour
        // matters most.
        Image(systemName: Self.symbol(thermal))
          .font(.system(size: 10))
          .foregroundStyle(Self.tint(thermal))
        Color.clear.frame(width: 0, height: 0)
      }
      .help(tooltip)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(tooltip)
    }
  }

  private func label(cpu: Double, thermal: ThermalLevel, lines: Bool) -> some View {
    HStack(spacing: 3) {
      Image(systemName: Self.symbol(thermal))
        .foregroundStyle(Self.tint(thermal))
      if let temperature = monitor.temperature {
        if lines {
          RangeLine(
            scale: Self.temperatureScale, band: monitor.temperatureRange,
            value: temperature.cpuAverage, tint: Self.tint(thermal))
        }
        Text(TemperatureReading.format(temperature.cpuAverage))
          .monospacedDigit()
        Text("·")
      }
      Text("CPU")
      if lines {
        RangeLine(
          scale: Self.cpuScale, band: monitor.cpuRange, value: cpu, tint: Self.tint(thermal))
      }
      Text(CPULoad.format(cpu))
        .monospacedDigit()
    }
    .font(.system(size: 10))
    .foregroundStyle(.secondary)
    .fixedSize()
  }

  static func symbol(_ thermal: ThermalLevel) -> String {
    switch thermal {
    case .nominal: return "thermometer.low"
    case .fair: return "thermometer.medium"
    case .serious, .critical: return "thermometer.high"
    }
  }

  /// Secondary until macOS says it's hot; then the same adaptive orange / red
  /// as the menu bar dot.
  static func tint(_ thermal: ThermalLevel) -> Color {
    thermal.asStrain.statusTint.map { Color(nsColor: $0) } ?? .secondary
  }
}

/// A value on a fixed scale, over the band it has covered recently: a faint
/// track, a stronger band from low to high, and a dot for now. One reading is
/// a dot with no band — a single point isn't a range.
struct RangeLine: View {
  let scale: ClosedRange<Double>
  let band: ClosedRange<Double>?
  let value: Double
  let tint: Color

  static let width: CGFloat = 26

  /// 0…1 along the track, clamped: off-scale readings sit at the ends.
  static func position(_ v: Double, in scale: ClosedRange<Double>) -> Double {
    guard scale.upperBound > scale.lowerBound else { return 0 }
    return min(max((v - scale.lowerBound) / (scale.upperBound - scale.lowerBound), 0), 1)
  }

  var body: some View {
    let w = Self.width
    ZStack(alignment: .leading) {
      Capsule().fill(Color.secondary.opacity(0.2)).frame(width: w, height: 2)
      if let band {
        let lo = Self.position(band.lowerBound, in: scale)
        let hi = Self.position(band.upperBound, in: scale)
        Capsule().fill(Color.secondary.opacity(0.55))
          .frame(width: max(w * (hi - lo), 2), height: 3)
          .offset(x: w * lo)
      }
      Circle().fill(tint == .secondary ? Color.primary.opacity(0.75) : tint)
        .frame(width: 5, height: 5)
        .offset(x: w * Self.position(value, in: scale) - 2.5)
    }
    .frame(width: w, height: 6)
  }
}

extension MemoryFormat {
  static func heatTooltip(
    cpu: Double, cpuRange: ClosedRange<Double>? = nil, thermal: ThermalLevel,
    temperature: TemperatureReading? = nil, temperatureRange: ClosedRange<Double>? = nil,
    busiest: [BusyProcess]
  ) -> String {
    var lines: [String] = []
    if let t = temperature {
      var line =
        "Temperature \(TemperatureReading.format(t.cpuAverage))C — CPU average of \(t.sensorCount) sensors; hottest core \(TemperatureReading.format(t.cpuMax))"
      if let gpu = t.gpuAverage { line += "; GPU \(TemperatureReading.format(gpu))" }
      lines.append(line)
      if let r = temperatureRange {
        lines.append(
          "Last 30 min: low \(TemperatureReading.format(r.lowerBound)), high \(TemperatureReading.format(r.upperBound))"
        )
      }
      if !t.fans.isEmpty {
        let speeds = t.fans.map { "\(Int($0.rpm.rounded()))" }.joined(separator: " / ")
        let ceiling = t.fans.map(\.max).max().map { " (max \(Int($0.rounded())))" } ?? ""
        lines.append("Fans \(speeds) rpm\(ceiling)")
      }
    }
    lines.append("Thermal state: \(thermal.label) — \(thermal.explanation)")
    var cpuLine =
      "CPU \(CPULoad.format(cpu)) of all \(ProcessInfo.processInfo.activeProcessorCount) cores "
      + "(100% = every core busy)"
    if let r = cpuRange {
      cpuLine += "; last 30 min \(CPULoad.format(r.lowerBound))–\(CPULoad.format(r.upperBound))"
    }
    lines.append(cpuLine)
    if !busiest.isEmpty {
      lines.append(
        "Busiest (% of one core, so up to \(ProcessInfo.processInfo.activeProcessorCount * 100)%): "
          + busiest.map(\.label).joined(separator: ", "))
    }
    return lines.joined(separator: "\n")
  }
}
