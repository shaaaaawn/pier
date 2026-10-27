import Foundation

// What an MCP server *is*, from its command line.
//
// Raw rows read "node · chr…vtools-mcp", "npm · …@latest", "xurl · mcp": the
// runtime first, the server truncated, and one server split across its
// launcher (`npm exec …`), the server process, and helpers it spawns. On the
// dev machine 17 rows covered 6 servers. This finds the package each process
// belongs to and names it the way a person would — "Chrome DevTools",
// "Browser Tools", "Blender" — so launcher, server and helpers share a name
// and collapse into one row.

struct MCPIdentity: Equatable {
  /// "Chrome DevTools"
  let name: String
  /// What it was launched as, for the subline: "chrome-devtools-mcp@latest",
  /// "@just-every/mcp-screenshot-website-fast", "xurl · api.x.com".
  let package: String
}

enum MCPNames {
  /// Runners whose next non-flag argument is the package they start.
  static let runners: [[String]] = [
    ["npm", "exec"], ["npx"], ["pnpm", "dlx"], ["pnpx"], ["bunx"], ["bun", "x"],
    ["yarn", "dlx"], ["uvx"], ["uv", "run"], ["uv", "tool", "run"], ["pipx", "run"],
    ["deno", "run"],
  ]

  static func identity(command: String) -> MCPIdentity? {
    guard let package = package(in: command) else { return nil }
    return MCPIdentity(name: humanName(package: package, command: command), package: package)
  }

  /// The package or tool this process belongs to.
  static func package(in command: String) -> String? {
    let tokens = command.split(separator: " ").map(String.init)
    let args = tokens.filter { !$0.hasPrefix("-") }
    let binaries = args.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }

    // 1. A runner: `npm exec chrome-devtools-mcp@latest`, `uv run blender-mcp`.
    for runner in runners where binaries.starts(with: runner) {
      if let target = args.dropFirst(runner.count).first { return target }
    }
    // 2. A Claude extension: ".../Claude Extensions/ant.dir.gh.blender.blender-mcp/…"
    //    (matched on the whole string: "Application Support" has a space).
    if let range = command.range(of: "Claude Extensions/") {
      let id = command[range.upperBound...].prefix { $0 != "/" }
      if let last = id.split(separator: ".").last { return String(last) }
    }
    // 3. A subcommand: `xurl mcp https://api.x.com/mcp` — the tool is the binary.
    if args.count >= 2, args[1] == "mcp" { return withHost(binaries[0], args: args) }
    // …or through a runtime shim, `node …/.bin/xurl mcp`: the tool is the shim.
    if args.count >= 3, args[2] == "mcp" {
      return withHost(URL(fileURLWithPath: args[1]).lastPathComponent, args: args)
    }
    // 4. Inside node_modules: `.bin/browser-tools-mcp`, or a package's own files
    //    (`node_modules/chrome-devtools-mcp/build/…/watchdog/main.js`).
    if let fromModules = nodeModulesPackage(in: command) { return fromModules }
    // 5. The executable itself is the server (`chrome-devtools-mcp`,
    //    `…/bin/blender-mcp`).
    if let first = binaries.first, isMCPish(first) { return first }
    // 6. A script whose path names it: `node ~/x/chrome-devtools-mcp/build/index.js`
    //    is the folder, not "index.js".
    if let script = args.dropFirst().first(where: isMCPish) {
      return script.split(separator: "/").last(where: { isMCPish(String($0)) }).map(String.init)
    }
    return nil
  }

  /// The package directory under the last `node_modules/`, scope included;
  /// `.bin/<name>` is the shim for `<name>`.
  static func nodeModulesPackage(in command: String) -> String? {
    guard let range = command.range(of: "node_modules/", options: .backwards) else { return nil }
    let parts = command[range.upperBound...].split(separator: "/", maxSplits: 3)
      .map { String($0.prefix { $0 != " " }) }
    guard let first = parts.first else { return nil }
    if first == ".bin", parts.count > 1 { return parts[1] }
    if first.hasPrefix("@"), parts.count > 1 { return "\(first)/\(parts[1])" }
    return first
  }

  static func isMCPish(_ s: String) -> Bool {
    let lower = s.lowercased()
    return lower.contains("mcp") || lower.contains("modelcontextprotocol")
  }

  /// `xurl` + `https://api.x.com/mcp` → "xurl · api.x.com".
  private static func withHost(_ tool: String, args: [String]) -> String {
    guard let url = args.first(where: { $0.hasPrefix("http") }).flatMap(URL.init(string:)),
      let host = url.host
    else { return tool }
    return "\(tool) · \(host)"
  }

  // MARK: - Naming

  /// Words with a canonical spelling. Everything else is capitalised.
  static let spellings: [String: String] = [
    "devtools": "DevTools", "github": "GitHub", "gitlab": "GitLab", "api": "API",
    "ui": "UI", "sqlite": "SQLite", "postgres": "Postgres", "mysql": "MySQL",
    "aws": "AWS", "gcp": "GCP", "npm": "npm", "ios": "iOS", "macos": "macOS",
    "openai": "OpenAI", "youtube": "YouTube", "linkedin": "LinkedIn", "url": "URL",
  ]

  /// Tools whose own name hides what they are.
  static let knownTools: [String: String] = ["xurl": "X API"]

  /// Leftovers that name nothing on their own.
  static let generic: Set<String> = ["", "process", "server", "index", "main", "cli", "app"]

  static func humanName(package: String, command: String) -> String {
    // Drop the host suffix, the version and the scope: "@just-every/mcp-x@1.2".
    var base = package.components(separatedBy: " · ").first ?? package
    if let at = base.lastIndex(of: "@"), at != base.startIndex { base = String(base[..<at]) }
    if base.hasPrefix("@"), let slash = base.firstIndex(of: "/") {
      base = String(base[base.index(after: slash)...])
    }
    let lower = base.lowercased()
    if let known = knownTools[lower] { return known }

    var core = lower
    for prefix in ["mcp-server-", "server-", "mcp-"] where core.hasPrefix(prefix) {
      core = String(core.dropFirst(prefix.count))
      break
    }
    for suffix in ["-mcp-server", "-mcp", "-server", "_mcp", ".mcp"] where core.hasSuffix(suffix) {
      core = String(core.dropLast(suffix.count))
      break
    }
    if generic.contains(core) {
      // "Cursor Helper: mcp-process" — the host app is the useful word.
      // Last path component only: "/usr/local/bin/npm" reads as "npm".
      let first = command.split(separator: " ").first.map(String.init) ?? base
      return "\(URL(fileURLWithPath: first).lastPathComponent) MCP"
    }
    return
      core
      .split(whereSeparator: { "-_. ".contains($0) })
      .map { word in
        let w = String(word)
        return spellings[w] ?? (w.prefix(1).uppercased() + w.dropFirst())
      }
      .joined(separator: " ")
  }
}
