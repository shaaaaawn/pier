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
    if let argv0 = lower.split(separator: " ").first,
      let basename = argv0.split(separator: "/").last,
      let label = harnessLabel(for: String(basename))
    {
      return label
    }

    let segments = lower.split(whereSeparator: { $0 == "/" || $0 == " " || $0 == "=" })
    for rule in harnessTable where !rule.pathTokens.isEmpty {
      for pathToken in rule.pathTokens {
        // Whole-segment or boundary-delimited hit inside a segment.
        if segments.contains(where: { segmentMatches(String($0), token: pathToken) }) {
          return rule.label
        }
      }
    }
    return nil
  }

  /// A path segment counts when it equals the token or contains it delimited by
  /// non-alphanumerics (`@anthropic-ai/claude-code`, `kimi-code-1.2`).
  static func segmentMatches(_ segment: String, token: String) -> Bool {
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

  /// Combine the cmux and harness signals for one listening port.
  ///
  /// `commands` maps pid → full command line (already gathered for MCP
  /// detection, so this costs no extra probe). Each link in the ancestor chain
  /// is tested by name first, then by command path, self before parents — a
  /// process is named by what it *is* before what launched it.
  /// Paths only macOS itself ships from. `/usr/libexec` and `/System` are
  /// SIP-protected; `/Library/Apple` holds Apple-managed daemons.
  static func isSystemBinary(_ command: String) -> Bool {
    let path = command.split(separator: " ").first.map(String.init) ?? command
    return path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
      || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/Library/Apple/")
  }

  static func attribute(
    entry: PortEntry, table: ProcessTable, cmux: CmuxSnapshot?,
    commands: [Int32: String] = [:]
  ) -> Attribution {
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
      if let command = commands[link.pid], let label = harnessLabel(fromCommand: command) {
        harness = label
        break
      }
    }
    if harness == nil { harness = harnessLabel(for: entry.processName) }

    if let cmux, let hit = cmux.attribution(chain: chain.map(\.pid)) {
      return .cmux(workspace: hit.workspace, surface: hit.surface, harness: harness)
    }
    if let harness { return .harness(harness) }
    return .none
  }
}
