import Foundation

/// Background activity that doesn't (necessarily) hold a listening port:
/// Docker containers, Apple `container` containers, and MCP server processes
/// (mostly stdio children of agent harnesses, invisible to lsof).
enum ActivityKind: String {
  case docker
  case apple
  case mcp

  var sectionTitle: String {
    switch self {
    case .docker: return "Docker"
    // Apple's CLI is just `container`, which is uselessly generic as a
    // heading — and a bare "Containers" next to "Docker" reads as though
    // Docker's containers were something else. Name the engine.
    case .apple: return "Apple Containers"
    case .mcp: return "MCP Servers"
    }
  }

  /// SF Symbol fallback, used when there's no bundled brand mark.
  var symbol: String {
    switch self {
    case .docker: return "shippingbox"
    case .apple: return "apple.logo"
    case .mcp: return "bolt.horizontal.circle"
    }
  }

  /// Bundled brand icon basename (Resources/icons/<name>.png), same mechanism
  /// as the harness marks. Apple's logo ships as an SF Symbol, so only Docker
  /// needs one.
  var iconName: String? {
    switch self {
    case .docker: return "docker"
    case .apple, .mcp: return nil
    }
  }
}

struct ActivityEntry: Identifiable, Equatable {
  let kind: ActivityKind
  /// Container name, or MCP display label ("node · chrome-devtools-mcp").
  let name: String
  /// Image · status for containers; full command line for MCP (tooltip).
  let detail: String
  /// Killable pids — MCP rows only (grouped duplicates share one row).
  var pids: [Int32] = []
  /// Host ports published by a Docker container.
  var ports: [Int] = []
  /// Harness/cmux attribution — MCP rows only.
  var attribution: Attribution = .none
  /// Summed CPU/memory across `pids` — MCP rows only (containers report no
  /// host pid, so their usage would need `docker stats`).
  var usage: Usage?
  /// Containers only: false for one that exists but isn't running. Stopped
  /// containers are listed so they can be started again — they're invisible to
  /// `docker ps` without `-a`, which is why an idle machine looked empty.
  var isRunning = true

  var id: String { "\(kind.rawValue):\(name):\(pids.first.map(String.init) ?? "-")" }
  var count: Int { max(pids.count, 1) }

  func matches(_ query: String) -> Bool {
    if query.isEmpty { return true }
    let q = query.lowercased()
    return name.lowercased().contains(q)
      || detail.lowercased().contains(q)
      || kind.sectionTitle.lowercased().contains(q)
      || attribution.badgeLabel.lowercased().contains(q)
      || ports.contains { String($0).contains(q) }
  }
}

struct ActivityGroup: Identifiable {
  let kind: ActivityKind
  let entries: [ActivityEntry]
  var id: String { kind.rawValue }
  var title: String { kind.sectionTitle }
  /// Total processes/containers behind the group (MCP rows may be grouped).
  var entryCount: Int { entries.reduce(0) { $0 + $1.count } }
  /// Containers present but not running — surfaced in the header so a section
  /// of stopped containers doesn't read as a section of running ones.
  var stoppedCount: Int { entries.filter { !$0.isRunning }.count }
}

enum ActivityParser {
  /// `docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'`.
  /// `-a` includes stopped containers; their Status reads "Exited (0) 3 hours
  /// ago" rather than "Up 3 hours".
  static func parseDockerPS(_ out: String) -> [ActivityEntry] {
    out.split(separator: "\n").compactMap { line in
      let f = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard f.count >= 2, !f[0].isEmpty else { return nil }
      let status = f.count >= 3 && !f[2].isEmpty ? String(f[2]) : "running"
      let ports = f.count >= 4 ? parsePublishedPorts(String(f[3])) : []
      return ActivityEntry(
        kind: .docker, name: String(f[0]),
        detail: "\(f[1]) · \(condenseStatus(status))", ports: ports,
        isRunning: dockerStatusIsRunning(status))
    }
  }

  /// Docker's Status column: "Up …" (and "Up … (healthy)") means running;
  /// "Exited …", "Created", "Paused", "Restarting" do not.
  static func dockerStatusIsRunning(_ status: String) -> Bool {
    status.lowercased().hasPrefix("up")
  }

  /// Docker's Status column is written for an 80-column terminal, not a 340pt
  /// panel: "postgres:16-alpine · Exited (0) 4 hours ago" middle-truncates into
  /// "postgres:16-al…(0) 4 hours ago", which reads as noise. Condense the units
  /// and drop the parens so the whole line fits.
  ///
  /// "Up 28 hours (healthy)" → "up 28h (healthy)"
  /// "Exited (0) 3 hours ago" → "exited 0, 3h ago"
  static func condenseStatus(_ status: String) -> String {
    var s = status
    s = s.replacingOccurrences(of: "Less than a second", with: "<1s")
    // Docker's fuzzy durations must be handled *before* the unit table, or
    // " minute" fires inside "a minute" and "About a minute" becomes "About am".
    s = s.replacingOccurrences(of: "About a minute", with: "~1m")
    s = s.replacingOccurrences(of: "About an hour", with: "~1h")
    s = s.replacingOccurrences(of: "a minute", with: "1m")
    s = s.replacingOccurrences(of: "an hour", with: "1h")
    s = s.replacingOccurrences(of: "(health: starting)", with: "(starting)")
    s = s.replacingOccurrences(
      of: #"^Exited \((\d+)\)"#, with: "exited $1,", options: .regularExpression)
    s = s.replacingOccurrences(of: #"^Up\b"#, with: "up", options: .regularExpression)
    // Longest first: "months" must not be eaten by the "month" rule.
    let units = [
      ("months", "mo"), ("month", "mo"), ("weeks", "w"), ("week", "w"),
      ("days", "d"), ("day", "d"), ("hours", "h"), ("hour", "h"),
      ("minutes", "m"), ("minute", "m"), ("seconds", "s"), ("second", "s"),
    ]
    for (long, short) in units {
      s = s.replacingOccurrences(of: " \(long)", with: short)
    }
    return s
  }

  /// Host ports from a docker Ports field, e.g.
  /// "0.0.0.0:8080->80/tcp, :::8080->80/tcp, 5432/tcp" → [8080].
  static func parsePublishedPorts(_ field: String) -> [Int] {
    var ports: Set<Int> = []
    for mapping in field.split(separator: ",") {
      guard let arrow = mapping.range(of: "->") else { continue }
      let host = mapping[..<arrow.lowerBound]
      guard let portStr = host.split(separator: ":").last, let port = Int(portStr) else { continue }
      ports.insert(port)
    }
    return ports.sorted()
  }

  /// Apple `container list --all` table (ID IMAGE OS ARCH STATE …), header
  /// skipped. `--all` includes stopped containers so they can be restarted.
  static func parseContainerList(_ out: String) -> [ActivityEntry] {
    out.split(separator: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .filter { !$0.uppercased().hasPrefix("ID") }
      .compactMap { line in
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let id = f.first else { return nil }
        let state = f.count >= 5 ? String(f[4]) : ""
        let detail = f.count >= 5 ? "\(f[1]) · \(state)" : (f.count >= 2 ? String(f[1]) : "")
        return ActivityEntry(
          kind: .apple, name: String(id), detail: detail,
          isRunning: state.lowercased() == "running")
      }
  }

  /// MCP server processes from `ps -axo pid=,user=,command=`: commands
  /// mentioning mcp/modelcontextprotocol, labeled "binary · mcp-segment",
  /// grouped by (label, attribution), attributed via the ancestor chain the
  /// same way listening ports are.
  static func mcpEntries(
    fullPS: String, table: ProcessTable, cmux: CmuxSnapshot?
  ) -> [ActivityEntry] {
    struct Raw {
      let pid: Int32
      let user: String
      let command: String
      let label: String
    }
    let mcpish = { (s: String) in s.contains("mcp") || s.contains("modelcontextprotocol") }
    let raws: [Raw] = fullPS.split(separator: "\n").compactMap { line in
      // ~1,000 lines arrive per refresh and a handful are MCP servers. Without
      // this, every line was split, re-joined and lowercased before the first
      // check could reject it.
      guard mightMentionMCP(line) else { return nil }
      let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard tokens.count >= 3, let pid = Int32(tokens[0]) else { return nil }
      let command = tokens.dropFirst(2).joined(separator: " ")
      let lower = command.lowercased()
      guard isMCPCommand(lower), !lower.hasPrefix("ps ") else { return nil }
      return Raw(
        pid: pid, user: String(tokens[1]), command: command,
        label: mcpLabel(command: command, mcpish: mcpish))
    }

    var order: [String] = []
    var grouped: [String: ActivityEntry] = [:]
    for raw in raws {
      let attribution = Attributor.attribute(
        pid: raw.pid, processName: raw.label, user: raw.user, table: table, cmux: cmux)
      let key = "\(raw.label)|\(attribution.badgeLabel)"
      if var entry = grouped[key] {
        entry.pids.append(raw.pid)
        grouped[key] = entry
      } else {
        order.append(key)
        grouped[key] = ActivityEntry(
          kind: .mcp, name: raw.label, detail: raw.command,
          pids: [raw.pid], attribution: attribution)
      }
    }
    return order.compactMap { grouped[$0] }.map { entry in
      var entry = entry
      entry.usage = table.usage(for: entry.pids)
      return entry
    }
  }

  private static let mcpNeedles: [[UInt8]] = [
    Array("mcp".utf8), Array("modelcontextprotocol".utf8),
  ]

  /// Cheap gate in front of `isMCPCommand`: can this raw `ps` line possibly
  /// contain an MCP token? It must never reject a line the full check would
  /// accept, so it scans the *whole* line (a superset of the tokens that check
  /// examines) for either needle — "modelcontextprotocol" has to be its own
  /// needle because it doesn't contain "mcp".
  ///
  /// ASCII case folding matches `lowercased()` exactly for these needles: the
  /// only non-ASCII scalars that lowercase into ASCII are the Kelvin sign (to
  /// "k") and "İ" (to "i" + a combining dot), and neither needle contains a
  /// "k" or an "i".
  static func mightMentionMCP(_ line: Substring) -> Bool {
    let bytes = line.utf8
    for needle in mcpNeedles where containsCaseInsensitiveASCII(bytes, needle) {
      return true
    }
    return false
  }

  private static func containsCaseInsensitiveASCII(
    _ haystack: Substring.UTF8View, _ needle: [UInt8]
  ) -> Bool {
    guard let first = needle.first else { return true }
    var start = haystack.startIndex
    while start != haystack.endIndex {
      // OR 0x20 folds ASCII A–Z onto a–z; needles are lowercase letters only.
      if haystack[start] | 0x20 == first {
        var h = start
        var matched = true
        for byte in needle {
          guard h != haystack.endIndex, haystack[h] | 0x20 == byte else {
            matched = false
            break
          }
          h = haystack.index(after: h)
        }
        if matched { return true }
      }
      start = haystack.index(after: start)
    }
    return false
  }

  /// Text tools that routinely *mention* mcp in their arguments — a grep or
  /// sed over MCP logs is not an MCP server. Matched on the binary name.
  private static let textTools: Set<String> = [
    "sed", "awk", "grep", "egrep", "fgrep", "rg", "ag", "ack", "cat", "tail",
    "head", "less", "more", "echo", "printf", "tr", "cut", "sort", "uniq",
    "wc", "xargs", "find", "jq", "git", "defaults", "open", "log", "man",
    "which", "ps", "pgrep", "pkill", "kill", "watch", "tee",
  ]

  /// A process IS an MCP server when the mcp-ish token sits in the command's
  /// head — the binary or an early positional arg — and the binary isn't a
  /// text tool merely quoting the word.
  ///
  /// Excluded on purpose: Chrome *launched by* chrome-devtools-mcp (mcp only
  /// in `--user-data-dir=…`), harness CLIs listing `mcp__…` tool names in flag
  /// values, and `grep mcp` / `sed …MCP…` pipelines.
  static func isMCPCommand(_ lower: String) -> Bool {
    let mcpish = { (s: String) in s.contains("mcp") || s.contains("modelcontextprotocol") }
    let tokens = lower.split(separator: " ").filter { !$0.hasPrefix("-") }
    guard let first = tokens.first else { return false }
    let binary = URL(fileURLWithPath: String(first)).lastPathComponent
    if textTools.contains(binary) { return false }
    return tokens.prefix(3).contains { mcpish(String($0)) }
  }

  /// "node /a/b/mcp-server/index.js" → "node · mcp-server";
  /// "@modelcontextprotocol/server-github" names the package after the scope.
  static func mcpLabel(command: String, mcpish: (String) -> Bool) -> String {
    let tokens = command.split(separator: " ")
    let binary = tokens.first.map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? "?"
    let hint = tokens.dropFirst().first { mcpish($0.lowercased()) }.flatMap { token -> String? in
      let segments = token.split(separator: "/")
      guard let i = segments.firstIndex(where: { mcpish($0.lowercased()) }) else { return nil }
      if segments[i].hasPrefix("@"), i + 1 < segments.count { return String(segments[i + 1]) }
      return String(segments[i])
    }
    let label = hint.map { "\(binary) · \($0)" } ?? binary
    return String(label.prefix(60))
  }
}

extension Attributor {
  /// Attribution for an arbitrary process (same signals as ports, minus the
  /// privileged-port test): root → system, else cmux surface, else harness.
  static func attribute(
    pid: Int32, processName: String, user: String, table: ProcessTable, cmux: CmuxSnapshot?
  ) -> Attribution {
    if user == "root" { return .system }
    let chain = table.chain(from: pid)
    let harness =
      chain.lazy.compactMap { harnessLabel(for: $0.name) }.first
      ?? harnessLabel(for: processName)
    if let cmux, let hit = cmux.attribution(chain: chain.map(\.pid)) {
      return .cmux(workspace: hit.workspace, surface: hit.surface, harness: harness)
    }
    if let harness { return .harness(harness) }
    return .none
  }
}
