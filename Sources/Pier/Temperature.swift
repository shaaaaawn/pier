import Foundation

/// One temperature / fan reading.
struct TemperatureReading: Equatable, Sendable {
  struct Fan: Equatable, Sendable {
    let rpm: Double
    let min: Double
    let max: Double
  }

  /// Mean of the CPU core sensors, °C — the headline: steadier than any one
  /// core, and what "how hot is it running" means.
  let cpuAverage: Double
  /// The hottest core, °C — what throttling actually responds to.
  let cpuMax: Double
  let gpuAverage: Double?
  let fans: [Fan]
  let sensorCount: Int

  /// Whole degrees are the display precision, so that's the publish gate.
  var displayKey: [Int] {
    [Int(cpuAverage.rounded()), Int(cpuMax.rounded()), Int((gpuAverage ?? 0).rounded())]
      + fans.map { Int($0.rpm / 50) }
  }

  static func format(_ celsius: Double) -> String { "\(Int(celsius.rounded()))°" }
}

/// Which SMC keys to read, chosen once from what the machine has.
struct SMCSensors: Equatable, Sendable {
  var cpu: [SMCKey] = []
  var gpu: [SMCKey] = []
  var fans: [(current: SMCKey, min: SMCKey?, max: SMCKey?)] = []

  static func == (a: Self, b: Self) -> Bool {
    a.cpu == b.cpu && a.gpu == b.gpu && a.fans.map(\.current) == b.fans.map(\.current)
  }

  var isEmpty: Bool { cpu.isEmpty }

  /// Plausible die temperatures, °C. Excludes unpopulated sensors (0, -127)
  /// and the odd non-temperature `T…` key.
  static let plausible: ClosedRange<Float> = 10...125

  /// Sensor families on Apple silicon: `Tp…` performance cores, `Te…`
  /// efficiency cores, `Tf…` (newer chips' core sensors), `Tg…` GPU. Chosen
  /// by family and by a plausible current value, never from a per-model list,
  /// so a new chip either works or shows no temperature — never a wrong one.
  static let cpuPrefixes = ["Tp", "Te", "Tf"]
  static let gpuPrefixes = ["Tg"]

  static func select(_ readings: [(key: SMCKey, value: Float?)]) -> SMCSensors {
    func family(_ prefixes: [String]) -> [SMCKey] {
      readings.filter { reading in
        guard reading.key.type == SMCCodec.floatType, let value = reading.value,
          plausible.contains(value)
        else { return false }
        return prefixes.contains { reading.key.name.hasPrefix($0) }
      }
      .map(\.key)
    }
    var sensors = SMCSensors(cpu: family(cpuPrefixes), gpu: family(gpuPrefixes))
    let byName = Dictionary(readings.map { ($0.key.name, $0.key) }, uniquingKeysWith: { a, _ in a })
    for n in 0..<10 {
      guard let current = byName["F\(n)Ac"], current.type == SMCCodec.floatType else { continue }
      sensors.fans.append((current, byName["F\(n)Mn"], byName["F\(n)Mx"]))
    }
    return sensors
  }
}

/// Low / high over a trailing window — the band on the footer's lines.
struct RollingRange: Equatable {
  let window: TimeInterval
  private(set) var samples: [(at: TimeInterval, value: Double)] = []

  init(window: TimeInterval) { self.window = window }

  static func == (a: Self, b: Self) -> Bool {
    a.window == b.window && a.samples.map(\.value) == b.samples.map(\.value)
  }

  mutating func add(_ value: Double, at time: TimeInterval) {
    samples.append((time, value))
    samples.removeAll { time - $0.at > window }
  }

  /// nil until there are two readings: one point is a value, not a range.
  var range: ClosedRange<Double>? {
    guard samples.count >= 2, let low = samples.map(\.value).min(),
      let high = samples.map(\.value).max()
    else { return nil }
    return low...high
  }
}

/// Owns the SMC connection and reads it on its own serial utility queue.
///
/// `@unchecked Sendable` because every stored property is touched only on
/// `queue` — the connection isn't thread-safe and never leaves it.
final class SensorSampler: @unchecked Sendable {
  private let queue = DispatchQueue(label: "pier.sensors", qos: .utility)
  private var connection: SMCConnection?
  private var sensors: SMCSensors?
  /// Fan min / max are fixed for the machine: read once at discovery, not on
  /// every reading.
  private var fanLimits: [(min: Double, max: Double)] = []
  /// Wall time of the last read, for `--print-memory`.
  private(set) var lastCost: TimeInterval = 0

  /// Reads in the background and calls back on the main queue; nil when the
  /// SMC won't open or the machine exposes no recognisable CPU sensors.
  func read(_ completion: @escaping @Sendable (TemperatureReading?) -> Void) {
    queue.async { [self] in
      let reading = readNow()
      DispatchQueue.main.async { completion(reading) }
    }
  }

  /// Synchronous, for probes. Call only off the main thread or from a probe.
  func readNow() -> TemperatureReading? {
    if sensors == nil {
      connection = SMCConnection()
      if let connection {
        let keys = connection.allKeys().filter { $0.name.hasPrefix("T") || $0.name.hasPrefix("F") }
        let selected = SMCSensors.select(keys.map { ($0, connection.float($0)) })
        sensors = selected
        fanLimits = selected.fans.map { fan in
          (
            Double(fan.min.flatMap(connection.float) ?? 0),
            Double(fan.max.flatMap(connection.float) ?? 0)
          )
        }
      } else {
        sensors = SMCSensors()
      }
    }
    guard let connection, let sensors, !sensors.isEmpty else { return nil }
    let started = Date()
    let cpu = sensors.cpu.compactMap { connection.float($0) }.map(Double.init)
      .filter { SMCSensors.plausible.contains(Float($0)) }
    let gpu = sensors.gpu.compactMap { connection.float($0) }.map(Double.init)
      .filter { SMCSensors.plausible.contains(Float($0)) }
    let fans = zip(sensors.fans, fanLimits).compactMap { fan, limits -> TemperatureReading.Fan? in
      guard let rpm = connection.float(fan.current) else { return nil }
      return TemperatureReading.Fan(rpm: Double(rpm), min: limits.min, max: limits.max)
    }
    lastCost = Date().timeIntervalSince(started)
    guard !cpu.isEmpty else { return nil }
    return TemperatureReading(
      cpuAverage: cpu.reduce(0, +) / Double(cpu.count), cpuMax: cpu.max() ?? 0,
      gpuAverage: gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count), fans: fans,
      sensorCount: cpu.count)
  }
}
