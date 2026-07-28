import Foundation

/// Something started or stopped between two refreshes — the answer to "what did
/// that agent just kill?".
///
/// Pier is a **poller**, not `EndpointSecurity`: events come from diffing
/// consecutive snapshots (5s while the panel is open, 30s when hidden), so a
/// process that starts *and* exits inside one interval is never seen. That's an
/// accepted limit, not a bug to chase — an ES client needs an entitlement Apple
/// grants case by case.
struct PierEvent: Identifiable, Equatable {
  enum Action: String, Equatable {
    case started
    case stopped

    var verb: String { rawValue }
    var symbol: String { self == .started ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
  }

  enum Subject: Equatable {
    case port(Int, process: String)
    case container(ActivityKind, String)
    case mcp(String)

    var name: String {
      switch self {
      case .port(let port, let process): return "\(process) on :\(port)"
      case .container(_, let name): return name
      case .mcp(let label): return label
      }
    }

    /// Stable identity across refreshes — the diff key.
    var key: String {
      switch self {
      case .port(let port, let process): return "port:\(process):\(port)"
      case .container(let kind, let name): return "\(kind.rawValue):\(name)"
      case .mcp(let label): return "mcp:\(label)"
      }
    }

    var kindLabel: String {
      switch self {
      case .port: return "port"
      case .container(let kind, _): return kind == .docker ? "Docker" : "container"
      case .mcp: return "MCP server"
      }
    }
  }

  let date: Date
  let action: Action
  let subject: Subject
  /// Who spawned the thing, when Pier could attribute it.
  let actor: Attribution
  /// Processes involved — MCP rows can lose several at once.
  var count: Int = 1
  /// True when *Pier itself* caused this (you clicked Stop). Without it, every
  /// button click in the panel alerts you about yourself ~5s later.
  var selfInitiated = false

  var id: String { "\(date.timeIntervalSince1970):\(action.rawValue):\(subject.key)" }

  /// One line for the feed and for `PierLog`.
  var summary: String {
    let who = selfInitiated ? "you" : actor.badgeLabel
    let what = count > 1 ? "\(subject.name) ×\(count)" : subject.name
    return "\(who) \(action.verb) \(what)"
  }
}

/// One refresh's worth of state — the unit the differ compares.
struct MonitorSnapshot: Equatable {
  var ports: [PortEntry] = []
  var activity: [ActivityEntry] = []
}

enum EventDiff {
  /// Events between two snapshots. `old == nil` is a **cold start**: it seeds
  /// the baseline and emits nothing, otherwise launching Pier would announce
  /// every one of the ~37 things already running.
  static func between(old: MonitorSnapshot?, new: MonitorSnapshot, at date: Date) -> [PierEvent] {
    guard let old else { return [] }
    return portEvents(old: old, new: new, at: date)
      + containerEvents(old: old, new: new, at: date)
      + mcpEvents(old: old, new: new, at: date)
  }

  private static func portEvents(old: MonitorSnapshot, new: MonitorSnapshot, at date: Date)
    -> [PierEvent]
  {
    // Keyed by process+port, not by pid: a dev server that restarts itself onto
    // the same port gets a new pid, and "stopped then started" is the truth
    // there — but a pid-only key would also fire for a port change alone.
    var events: [PierEvent] = []
    let before = Dictionary(old.ports.map { (portKey($0), $0) }, uniquingKeysWith: { a, _ in a })
    let after = Dictionary(new.ports.map { (portKey($0), $0) }, uniquingKeysWith: { a, _ in a })
    for (key, entry) in after where before[key] == nil {
      events.append(
        PierEvent(
          date: date, action: .started,
          subject: .port(entry.port, process: entry.processName), actor: entry.attribution))
    }
    for (key, entry) in before where after[key] == nil {
      events.append(
        PierEvent(
          date: date, action: .stopped,
          subject: .port(entry.port, process: entry.processName), actor: entry.attribution))
    }
    return events.sorted { $0.subject.key < $1.subject.key }
  }

  private static func portKey(_ entry: PortEntry) -> String {
    "\(entry.processName):\(entry.port):\(entry.proto.rawValue)"
  }

  /// Containers flip `isRunning` rather than appearing and disappearing — both
  /// engines are listed with `-a`/`--all`, so a `docker stop` leaves the row in
  /// place. Diffing on presence would miss every stop.
  private static func containerEvents(old: MonitorSnapshot, new: MonitorSnapshot, at date: Date)
    -> [PierEvent]
  {
    var events: [PierEvent] = []
    let before = Dictionary(
      old.activity.filter { $0.kind != .mcp }.map { ("\($0.kind.rawValue):\($0.name)", $0) },
      uniquingKeysWith: { a, _ in a })
    let after = Dictionary(
      new.activity.filter { $0.kind != .mcp }.map { ("\($0.kind.rawValue):\($0.name)", $0) },
      uniquingKeysWith: { a, _ in a })

    for (key, entry) in after {
      let subject = PierEvent.Subject.container(entry.kind, entry.name)
      if let previous = before[key] {
        if previous.isRunning != entry.isRunning {
          events.append(
            PierEvent(
              date: date, action: entry.isRunning ? .started : .stopped,
              subject: subject, actor: entry.attribution))
        }
      } else if entry.isRunning {
        // A container created in a stopped state isn't a start.
        events.append(
          PierEvent(date: date, action: .started, subject: subject, actor: entry.attribution))
      }
    }
    // Removed while running counts as stopped; removing an already-stopped
    // container is housekeeping, not a kill.
    for (key, entry) in before where after[key] == nil && entry.isRunning {
      events.append(
        PierEvent(
          date: date, action: .stopped, subject: .container(entry.kind, entry.name),
          actor: entry.attribution))
    }
    return events.sorted { $0.subject.key < $1.subject.key }
  }

  /// MCP rows are grouped (one row, ×N processes), so a partial kill shows up
  /// as a count change — exactly the "an agent killed some of its servers" case.
  private static func mcpEvents(old: MonitorSnapshot, new: MonitorSnapshot, at date: Date)
    -> [PierEvent]
  {
    var events: [PierEvent] = []
    let before = Dictionary(
      old.activity.filter { $0.kind == .mcp }.map { (mcpKey($0), $0) },
      uniquingKeysWith: { a, _ in a })
    let after = Dictionary(
      new.activity.filter { $0.kind == .mcp }.map { (mcpKey($0), $0) },
      uniquingKeysWith: { a, _ in a })

    for (key, entry) in after {
      let subject = PierEvent.Subject.mcp(entry.name)
      guard let previous = before[key] else {
        events.append(
          PierEvent(
            date: date, action: .started, subject: subject, actor: entry.attribution,
            count: entry.count))
        continue
      }
      let delta = entry.count - previous.count
      if delta != 0 {
        events.append(
          PierEvent(
            date: date, action: delta > 0 ? .started : .stopped, subject: subject,
            actor: entry.attribution, count: abs(delta)))
      }
    }
    for (key, entry) in before where after[key] == nil {
      events.append(
        PierEvent(
          date: date, action: .stopped, subject: .mcp(entry.name), actor: entry.attribution,
          count: entry.count))
    }
    return events.sorted { $0.subject.key < $1.subject.key }
  }

  /// Label plus actor: the same server run by two harnesses is two rows, and
  /// merging them would report a phantom count change when one exits.
  private static func mcpKey(_ entry: ActivityEntry) -> String {
    "mcp:\(entry.name)|\(entry.attribution.badgeLabel)"
  }
}
