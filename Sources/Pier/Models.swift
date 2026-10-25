import Foundation

enum PortProtocol: String {
  case tcp = "TCP"
  case udp = "UDP"
}

/// Who/what spawned the process behind a listening port.
enum Attribution: Equatable {
  /// Attributed to a cmux surface (optionally with a detected harness name).
  case cmux(workspace: String, surface: String, harness: String?)
  /// Attributed to a known agent harness / terminal in the ancestor chain.
  case harness(String)
  /// A Ghostty / Terminal tab, told apart by its working directory and tty.
  case terminal(TerminalSession)
  /// Root-owned process or privileged port (< 1024).
  case system
  /// No attribution found.
  case none

  var badgeLabel: String {
    switch self {
    case .cmux(let workspace, let surface, let harness):
      var parts = ["cmux", workspace, surface]
      if let harness, harness.lowercased() != surface.lowercased() {
        parts.append(harness)
      }
      return parts.joined(separator: " · ")
    case .harness(let name): return name
    case .terminal(let session): return session.title
    case .system: return "system"
    case .none: return "local"
    }
  }

  var groupTitle: String {
    switch self {
    case .cmux(let workspace, _, _): return "cmux · \(workspace)"
    case .harness(let name): return name
    case .terminal(let session): return session.title
    case .system: return "System"
    case .none: return "Other"
    }
  }

  /// Brand icon resource basename (Resources/icons/<name>.png), if the
  /// attribution resolved to a harness that has one bundled.
  var iconName: String? {
    switch self {
    case .cmux(_, _, let harness):
      return harness.flatMap { Attributor.iconName(forHarnessLabel: $0) }
    case .harness(let name):
      return Attributor.iconName(forHarnessLabel: name)
    case .terminal(let session):
      return Attributor.iconName(forHarnessLabel: session.app.label)
    case .system, .none:
      return nil
    }
  }

  /// Badge label shortened to fit `maxChars`, preserving the leading
  /// kind · workspace segments and dropping the surface first; the full
  /// label stays available via tooltip.
  func smartBadgeLabel(maxChars: Int = 30) -> String {
    let full = badgeLabel
    guard full.count > maxChars else { return full }
    let parts = full.components(separatedBy: " · ")
    guard parts.count >= 2 else {
      return String(full.prefix(max(1, maxChars - 1))) + "…"
    }
    let head = parts[0...1].joined(separator: " · ")
    if parts.count >= 3 {
      // Prefer keeping the trailing segment: kind · workspace · … · surface
      let withTail = "\(head) · … · \(parts[parts.count - 1])"
      if withTail.count <= maxChars { return withTail }
    }
    let headOnly = "\(head) · …"
    if headOnly.count <= maxChars { return headOnly }
    return String(headOnly.prefix(max(1, maxChars - 1))) + "…"
  }

  /// What the row's badge should say *given its group header already says
  /// `title`* — nil when the badge would just repeat the header.
  ///
  /// Rows live under a header naming their attribution, so "Cursor" under a
  /// "Cursor" header is pure duplication. cmux is the one case with more to
  /// say: the header carries the workspace, the row adds the surface.
  func rowBadge(inGroup title: String) -> String? {
    let full = badgeLabel
    if full == title { return nil }
    // "cmux · ws · surface" under "cmux · ws" → just "surface".
    let prefix = title + " · "
    if full.hasPrefix(prefix) {
      let remainder = String(full.dropFirst(prefix.count))
      return remainder.isEmpty ? nil : remainder
    }
    switch self {
    // Generic buckets: the header ("Other" / "System") already says it.
    case .system, .none: return nil
    case .cmux, .harness, .terminal: return full
    }
  }

  /// Lower sorts first: attributed groups, then unattributed, then system.
  var groupRank: Int {
    switch self {
    case .cmux, .harness, .terminal: return 0
    case .none: return 1
    case .system: return 2
    }
  }
}

struct PortEntry: Identifiable, Equatable {
  let pid: Int32
  let port: Int
  let proto: PortProtocol
  let processName: String
  let user: String
  var bindAddresses: [String]
  var attribution: Attribution
  /// Live CPU/memory for `pid`, when the process table had a reading.
  var usage: Usage?
  /// cmux surface ref (e.g. "surface:19") owning this process, when cmux
  /// resolved one — the handle needed to read that surface's scrollback, which
  /// is the only way a dev server's own output becomes readable from outside.
  var cmuxSurfaceRef: String?

  var id: String { "\(pid):\(port):\(proto.rawValue)" }
  var bindSummary: String { bindAddresses.joined(separator: ", ") }

  /// URL used for the inline preview and open-in-browser.
  /// IPv4 wildcard/loopback binds map to 127.0.0.1; IPv6 wildcard/loopback
  /// binds map to [::1] (an ::1-only listener refuses IPv4 connections);
  /// other binds use their host.
  var previewURL: URL? {
    guard proto == .tcp, let host = preferredBindHost else { return nil }
    return URL(string: "http://\(host):\(port)")
  }

  /// Prefers an explicit loopback bind when several exist, else the first.
  private var preferredBindHost: String? {
    guard !bindAddresses.isEmpty else { return nil }
    let bind = bindAddresses.contains("127.0.0.1") ? "127.0.0.1" : bindAddresses[0]
    return Self.previewHost(for: bind)
  }

  static func previewHost(for bind: String) -> String {
    switch bind {
    case "*", "0.0.0.0": return "127.0.0.1"
    case "::", "::1", "[::]", "[::1]": return "[::1]"
    default: return bind
    }
  }

  /// `host:port` for the preview address bar (scheme omitted, IPv6 bracketed).
  var previewDisplayAddress: String? {
    guard let url = previewURL, let host = url.host else { return nil }
    let bracketed = host.contains(":") ? "[\(host)]" : host
    return "\(bracketed):\(port)"
  }

  func matches(_ query: String) -> Bool {
    if query.isEmpty { return true }
    let q = query.lowercased()
    return String(port).contains(q)
      || processName.lowercased().contains(q)
      || attribution.badgeLabel.lowercased().contains(q)
      || attribution.groupTitle.lowercased().contains(q)
      || bindAddresses.contains { $0.lowercased().contains(q) }
  }
}

/// One display row: either a single listener or a cluster of listeners
/// sharing pid + attribution (e.g. a workerd holding five ports).
struct PortRow: Identifiable {
  /// Visible children, sorted by port (filtered set when searching).
  let entries: [PortEntry]
  /// Full cluster size (== entries.count when unfiltered).
  let totalCount: Int
  /// True when a search matched only some children — UI should auto-expand.
  let autoExpanded: Bool

  var isCluster: Bool { totalCount > 1 }
  var primary: PortEntry { entries[0] }
  var id: String {
    isCluster
      ? "cluster-\(primary.pid)-\(primary.attribution.badgeLabel)"
      : primary.id
  }
}

struct PortGroup: Identifiable {
  let title: String
  let rank: Int
  let rows: [PortRow]
  var id: String { title }
  var entryCount: Int { rows.reduce(0) { $0 + $1.entries.count } }
}

/// One rendered section of the list, in display order.
enum PierSection: Identifiable {
  case ports(PortGroup)
  case activity(ActivityGroup)

  var id: String {
    switch self {
    case .ports(let group): return "ports-\(group.id)"
    case .activity(let group): return "activity-\(group.id)"
    }
  }

  /// Section order: attributed harness/cmux groups, then the container and MCP
  /// engines, then the catch-alls. Containers are things you *chose* to run, so
  /// they belong above "Other" and "System" noise rather than after it.
  static func ordered(ports: [PortGroup], activity: [ActivityGroup]) -> [PierSection] {
    let attributed = ports.filter { $0.rank == 0 }.map(PierSection.ports)
    let leftovers = ports.filter { $0.rank > 0 }.map(PierSection.ports)
    return attributed + activity.map(PierSection.activity) + leftovers
  }
}

/// Scope chips above the list. Narrows *which kinds of rows* are shown;
/// composes with the search text and the hide-system toggle.
enum PierFilter: String, CaseIterable, Identifiable {
  case all
  case web
  case ports
  case containers
  case mcp

  var id: String { rawValue }

  var label: String {
    switch self {
    case .all: return "All"
    case .web: return "Web"
    case .ports: return "Ports"
    // Umbrella over both engines — the Docker and Apple Containers sections
    // sit side by side beneath it, neither nested under the other.
    case .containers: return "Containers"
    case .mcp: return "MCP"
    }
  }

  var symbol: String {
    switch self {
    case .all: return "square.grid.2x2"
    case .web: return "globe"
    case .ports: return "network"
    case .containers: return "shippingbox"
    case .mcp: return "bolt.horizontal.circle"
    }
  }

  /// Does this scope show listening-port rows at all?
  var showsPorts: Bool {
    switch self {
    case .all, .web, .ports: return true
    case .containers, .mcp: return false
    }
  }

  /// Activity kinds this scope shows.
  var activityKinds: [ActivityKind] {
    switch self {
    case .all: return [.docker, .apple, .simulator, .mcp]
    // Simulators sit with containers: the other heavyweight, start-and-forget
    // guests that quietly hold gigabytes of RAM.
    case .containers: return [.docker, .apple, .simulator]
    case .mcp: return [.mcp]
    case .web, .ports: return []
    }
  }

  /// `web` keeps only rows with a browsable URL (TCP).
  func admits(_ entry: PortEntry) -> Bool {
    self == .web ? entry.previewURL != nil : true
  }
}

/// Desktop-ish CSS viewport widths for the inline preview. The webview's
/// pageZoom is set to cardWidth / width, which *reflows* the page (Safari
/// Cmd+− behavior) so responsive sites pick their desktop layout instead of
/// rendering a phone/watch column in a 400pt card.
enum PreviewViewport: Int, CaseIterable, Identifiable {
  case desktop = 1280
  case wide = 1440
  case laptop = 1024
  case native = 0

  var id: Int { rawValue }

  var label: String {
    switch self {
    case .desktop: return "1280"
    case .wide: return "1440"
    case .laptop: return "1024"
    case .native: return "Fit"
    }
  }

  var help: String {
    self == .native
      ? "Native width (no zoom) — the page sees the card's real width"
      : "Render as a \(rawValue)px-wide desktop viewport"
  }

  /// Aspect (height / width) used to size the card — 16:10 for desktop
  /// presets so the preview reads like a monitor.
  var aspect: CGFloat { self == .native ? 0.78 : 0.625 }

  /// pageZoom for a card `cardWidth` points wide. Clamped to WebKit's
  /// sane range; `native` means no zoom.
  func zoom(cardWidth: CGFloat) -> CGFloat {
    guard rawValue > 0, cardWidth > 0 else { return 1 }
    return max(0.2, min(1, cardWidth / CGFloat(rawValue)))
  }
}
