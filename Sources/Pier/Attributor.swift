import Foundation

/// A known agent harness / terminal. `icon` is the basename (no extension) of
/// a 32px PNG in Sources/Pier/Resources/icons/ — nil means text-only badge.
struct HarnessRule {
  /// Matched against the process name (`ps ucomm`) on a word boundary.
  let token: String
  let label: String
  let icon: String?
  /// Distinctive fragments safe to look for inside a full **command path**.
  ///
  /// Needed because many harnesses run as `node /path/to/<tool>/cli.js`, where
  /// the process name is just `node` and only the path identifies the tool.
  /// Opt-in per rule, and deliberately empty for generic words: `code` would
  /// match every project under `~/code/`, `pi` matches `pi-workflow`, `amp`
  /// and `zed` are short enough to appear anywhere. Those stay name-only.
  var pathTokens: [String] = []
}

/// Known agent harnesses / terminals, matched as a lowercased prefix against
/// the process name (`ps ucomm`). Order matters only for prefix overlaps —
/// keep more specific tokens first. Extend here (and run
/// scripts/convert-icons.sh when adding an icon).
let harnessTable: [HarnessRule] = [
  HarnessRule(
    token: "claude", label: "Claude Code", icon: "claude-code",
    pathTokens: ["claude-code", "@anthropic-ai/claude"]),
  // Antigravity's CLI installs as `agy` (~/.local/bin/agy) — nothing in the
  // name hints at the product, so without this rule its ports get attributed
  // to whatever launched it (CodexBar shells out to it for usage stats).
  HarnessRule(token: "agy", label: "Antigravity", icon: "antigravity", pathTokens: ["antigravity"]),
  // Before "codex": CodexBar is a usage *monitor*, not the Codex CLI, and its
  // children hold ports of their own. Naming it beats lumping it into "Other",
  // and it stays a fallback for children Pier can't identify directly.
  HarnessRule(token: "codexbar", label: "CodexBar", icon: nil),
  HarnessRule(token: "codex", label: "Codex", icon: "codex", pathTokens: ["codex-cli"]),
  HarnessRule(token: "opencode", label: "OpenCode", icon: "opencode", pathTokens: ["opencode"]),
  HarnessRule(
    token: "kimi", label: "Kimi", icon: "kimi-code", pathTokens: ["kimi-code", "kimi-cli"]),
  HarnessRule(token: "gemini", label: "Gemini CLI", icon: nil, pathTokens: ["gemini-cli"]),
  HarnessRule(token: "aider", label: "Aider", icon: "aider", pathTokens: ["aider"]),
  HarnessRule(token: "cursor", label: "Cursor", icon: "cursor", pathTokens: ["cursor-agent"]),
  HarnessRule(token: "windsurf", label: "Windsurf", icon: "windsurf", pathTokens: ["windsurf"]),
  HarnessRule(token: "amp", label: "Amp", icon: "amp"),
  HarnessRule(token: "copilot", label: "Copilot", icon: "copilot", pathTokens: ["copilot"]),
  HarnessRule(token: "crush", label: "Crush", icon: "crush"),
  HarnessRule(token: "goose", label: "Goose", icon: "goose"),
  // Popular harnesses that mostly run as `node <path>` / `python -m <pkg>`,
  // where only the path names the tool.
  HarnessRule(token: "cline", label: "Cline", icon: "cline", pathTokens: ["cline"]),
  HarnessRule(
    token: "kilo", label: "Kilo Code", icon: "kilo", pathTokens: ["kilo-code", "kilocode"]),
  HarnessRule(token: "roo", label: "Roo Code", icon: "roo", pathTokens: ["roo-code", "roocode"]),
  HarnessRule(token: "kiro", label: "Kiro", icon: "kiro", pathTokens: ["kiro"]),
  HarnessRule(token: "junie", label: "Junie", icon: "junie", pathTokens: ["junie"]),
  HarnessRule(token: "jules", label: "Jules", icon: "jules"),
  HarnessRule(
    token: "droid", label: "Factory Droid", icon: "factory-droid", pathTokens: ["factory-droid"]),
  HarnessRule(token: "qwen", label: "Qwen Code", icon: "qwen-code", pathTokens: ["qwen-code"]),
  HarnessRule(token: "qoder", label: "Qoder", icon: "qoder", pathTokens: ["qoder"]),
  HarnessRule(token: "refact", label: "Refact.ai", icon: "refact-ai", pathTokens: ["refact"]),
  HarnessRule(token: "comate", label: "Baidu Comate", icon: "baidu-comate", pathTokens: ["comate"]),
  HarnessRule(token: "codebuddy", label: "CodeBuddy", icon: "codebuddy", pathTokens: ["codebuddy"]),
  HarnessRule(token: "openhands", label: "OpenHands", icon: "openhands", pathTokens: ["openhands"]),
  HarnessRule(token: "devin", label: "Devin", icon: "devin", pathTokens: ["devin"]),
  HarnessRule(
    token: "augment", label: "Augment Code", icon: "augment-code", pathTokens: ["augment-code"]),
  HarnessRule(
    token: "mistral", label: "Mistral Vibe", icon: "mistral-vibe", pathTokens: ["mistral-vibe"]),
  HarnessRule(token: "trae", label: "Trae", icon: "trae", pathTokens: ["trae-agent"]),
  HarnessRule(token: "zencoder", label: "Zencoder", icon: "zencoder", pathTokens: ["zencoder"]),
  HarnessRule(token: "sweep", label: "Sweep", icon: "sweep"),
  HarnessRule(
    token: "replit", label: "Replit Agent", icon: "replit-agent", pathTokens: ["replit-agent"]),
  HarnessRule(token: "coco", label: "Snowflake Coco", icon: "snowflake-coco"),
  HarnessRule(token: "mimo", label: "MiMo Code", icon: "mimo-code", pathTokens: ["mimo-code"]),
  HarnessRule(token: "genie", label: "Cosine Genie", icon: "cosine-genie"),
  // `pi` is name-only on purpose: as a path fragment it would match
  // `~/code/pi-workflow`, `site-packages/pip`, and similar.
  HarnessRule(token: "pi", label: "Pi", icon: "pi"),
  HarnessRule(token: "warp", label: "Warp", icon: "warp"),
  HarnessRule(token: "zed", label: "Zed", icon: "zed"),
  HarnessRule(token: "code", label: "VS Code", icon: nil),
  HarnessRule(token: "ghostty", label: "Ghostty", icon: nil),
  HarnessRule(token: "iterm2", label: "iTerm", icon: nil),
  HarnessRule(token: "terminal", label: "Terminal", icon: nil),
  HarnessRule(token: "tmux", label: "tmux", icon: nil),
  HarnessRule(token: "zellij", label: "Zellij", icon: nil),
]

enum Attributor {
  static func harnessLabel(for processName: String) -> String? {
    let name = processName.lowercased()
    for rule in harnessTable where matches(name: name, token: rule.token) {
      return rule.label
    }
    return nil
  }

  /// Token match on a word boundary, not a bare prefix.
  ///
  /// A plain `hasPrefix` mislabels neighbours that merely start the same way:
  /// `CodexBar` (a usage monitor) was reported as the Codex harness, so its
  /// ports looked like agent sessions and "killing Codex" did nothing you
  /// could see. A trailing letter/digit means it's a different word; `-`, `_`,
  /// `.`, or a space still counts (`claude-code`, `Cursor Helper`).
  static func matches(name: String, token: String) -> Bool {
    guard name.hasPrefix(token) else { return false }
    let next = name.dropFirst(token.count).first
    guard let next else { return true }  // exact match
    return !next.isLetter && !next.isNumber
  }

  /// Icon resource basename for a harness label, if one is bundled.
  static func iconName(forHarnessLabel label: String) -> String? {
    harnessTable.first { $0.label == label }?.icon
  }

  /// Identify a harness from a full command line — the case `ucomm` can't see,
  /// because a wrapper-style CLI shows up only as `node` or `python3`.
  ///
  /// Matching is on **path segments**, against `pathTokens` only, so generic
  /// rules (`code`, `pi`, `amp`) never fire here. A segment matches when the
  /// token sits on a word boundary within it, which lets `kimi-code` hit the
  /// `kimi-code` token while `mykimicode` doesn't.
  static func harnessLabel(fromCommand command: String) -> String? {
    guard !command.isEmpty else { return nil }
    let lower = command.lowercased()

    // The executable's own basename is effectively the process name, and it's
    // often the only identifying part (`~/.local/bin/agy`). Safe to match name
    // tokens against — unlike directories, it *is* the tool.
    // First token only — splitting the whole line just to read its head cost
    // an array of every token, on command lines that run past 9,000 chars.
    let argv0 = firstToken(lower)
    if !argv0.isEmpty, let basename = argv0.split(separator: "/").last,
      let label = harnessLabel(for: String(basename))
    {
      return label
    }

    // Most commands contain none of the path tokens. A segment can only match
    // a token the whole line contains, so check that first, on bytes: scanning
    // every segment for every token was ~10,000 Foundation range(of:) calls on
    // a single long command line.
    let bytes = Array(lower.utf8)
    let present = harnessTable.contains { rule in
      rule.pathTokens.contains { utf8Contains(bytes, $0) }
    }
    guard present else { return nil }

    let segments = lower.split(whereSeparator: { $0 == "/" || $0 == " " || $0 == "=" })
    for rule in harnessTable where !rule.pathTokens.isEmpty {
      for pathToken in rule.pathTokens where utf8Contains(bytes, pathToken) {
        // Whole-segment or boundary-delimited hit inside a segment.
        // Substrings straight through: converting each segment to a String
        // here allocated once per segment, per token, per rule.
        if segments.contains(where: { segmentMatches($0, token: pathToken) }) {
          return rule.label
        }
      }
    }
    return nil
  }

  /// A path segment counts when it equals the token or contains it delimited by
  /// non-alphanumerics (`@anthropic-ai/claude-code`, `kimi-code-1.2`).
  static func segmentMatches<S: StringProtocol>(_ segment: S, token: String) -> Bool {
    if segment == token { return true }
    guard let range = segment.range(of: token) else { return false }
    let before =
      range.lowerBound == segment.startIndex
      ? nil : segment[segment.index(before: range.lowerBound)]
    let after = range.upperBound == segment.endIndex ? nil : segment[range.upperBound]
    let okBefore = before.map { !$0.isLetter && !$0.isNumber } ?? true
    let okAfter = after.map { !$0.isLetter && !$0.isNumber } ?? true
    return okBefore && okAfter
  }

  /// Plain byte substring search. Both sides are already lowercased; the
  /// haystack is converted once per command line by the caller.
  static func utf8Contains(_ h: [UInt8], _ needle: String) -> Bool {
    let n = Array(needle.utf8)
    guard !n.isEmpty, n.count <= h.count else { return n.isEmpty }
    let first = n[0]
    var i = 0
    while i <= h.count - n.count {
      if h[i] == first {
        var j = 1
        while j < n.count, h[i + j] == n[j] { j += 1 }
        if j == n.count { return true }
      }
      i += 1
    }
    return false
  }

  /// The first space-delimited token, ignoring leading spaces — what
  /// `split(separator: " ").first` returns, without building every token.
  static func firstToken(_ text: String) -> Substring {
    text.drop(while: { $0 == " " }).prefix(while: { $0 != " " })
  }

  /// Paths only macOS itself ships from. `/usr/libexec` and `/System` are
  /// SIP-protected; `/Library/Apple` holds Apple-managed daemons.
  static func isSystemBinary(_ command: String) -> Bool {
    let head = firstToken(command)
    let path = head.isEmpty ? Substring(command) : head
    return path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
      || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/Library/Apple/")
  }

  /// Combine the cmux and harness signals for one listening port.
  ///
  /// `commands` maps pid → full command line (already gathered for MCP
  /// detection, so this costs no extra probe). Each link in the ancestor chain
  /// is tested by name first, then by command path, self before parents — a
  /// process is named by what it *is* before what launched it.
  static func attribute(
    entry: PortEntry, table: ProcessTable, cmux: CmuxSnapshot?,
    commands: [Int32: String] = [:]
  ) -> Attribution {
    attribute(entry: entry, table: table, cmux: cmux, labels: CommandLabelCache(commands))
  }

  /// Same decision, with command-line harness lookups shared through `labels`.
  /// One refresh attributes every port, and ports spawned by one agent session
  /// share the same ancestors — measured on a real machine, up to 616 chain
  /// links resolved to only 166 distinct pids — so each command line (some over
  /// 9,000 characters) should be lowercased and scanned once, not per port.
  ///
  /// `terminalInfo` reads a session leader's tty and directory (libproc in a
  /// real refresh). Only called for ports whose nearest harness is Ghostty or
  /// Terminal; when it can't say, the port keeps the plain terminal label.
  static func attribute(
    entry: PortEntry, table: ProcessTable, cmux: CmuxSnapshot?,
    labels: CommandLabelCache,
    terminalInfo: (Int32) -> TerminalSessionInfo? = { _ in nil }
  ) -> Attribution {
    let commands = labels.commands
    if entry.user == "root" || entry.port < 1024 { return .system }
    // Apple's own services run as *you* on unprivileged ports — ControlCenter's
    // AirPlay Receiver sits on :5000, indistinguishable from a Flask app by user
    // and port alone, and it outranked real dev servers in the activity sort.
    // The executable path is the honest tell, and it needs no vendor list: SIP
    // means nothing of yours ever lives under these prefixes.
    if let command = commands[entry.pid], isSystemBinary(command) { return .system }

    let chain = table.chain(from: entry.pid)
    var harness: String?
    for link in chain {
      if let label = harnessLabel(for: link.name) {
        harness = label
        break
      }
      if let label = labels.label(for: link.pid) {
        harness = label
        break
      }
    }
    if harness == nil { harness = harnessLabel(for: entry.processName) }

    if let cmux, let hit = cmux.attribution(chain: chain.map(\.pid)) {
      return .cmux(workspace: hit.workspace, surface: hit.surface, harness: harness)
    }
    // A plain terminal is only the answer when nothing more specific was found
    // first: Claude Code running in Ghostty stays "Claude Code".
    if let harness, let leader = TerminalSessions.leader(in: chain),
      harness == leader.app.label,
      let session = TerminalSessions.session(app: leader.app, info: terminalInfo(leader.pid))
    {
      return .terminal(session)
    }
    if let harness { return .harness(harness) }
    return .none
  }
}

/// Memoizes `Attributor.harnessLabel(fromCommand:)` per pid for one refresh.
///
/// A class so a single instance is shared across every entry assembled in that
/// refresh. Never keep one longer: pids get reused, and a cached label would
/// then belong to a process that no longer exists.
final class CommandLabelCache {
  let commands: [Int32: String]
  private var labels: [Int32: String?] = [:]

  init(_ commands: [Int32: String]) {
    self.commands = commands
  }

  func label(for pid: Int32) -> String? {
    if let cached = labels[pid] { return cached }
    let label = commands[pid].flatMap { Attributor.harnessLabel(fromCommand: $0) }
    labels[pid] = .some(label)
    return label
  }
}
