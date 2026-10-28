import Foundation

/// Pier's own local log file — `~/Library/Logs/Pier/pier.log`, the standard
/// macOS place for an app's logs (Console.app reads it, and it survives a
/// crash, unlike stderr for a GUI app nobody launched from a terminal).
///
/// Deliberately a plain file rather than `os_log`: Pier is an LSUIElement app
/// with no terminal attached, and `log show --predicate` is a poor experience
/// for "what did the app just do". A file you can `tail -f` wins.
///
/// **What is logged:** lifecycle, engine actions (start/stop/prune), container
/// start/stop, process kills, engine state transitions, and errors.
/// **What is never logged:** full command lines, environment variables, cmux
/// socket passwords, or scan output. Those can carry secrets — see
/// `redact(_:)`, which is the backstop, not the primary defense. The primary
/// defense is that callers pass verbs and names, not argv.
final class PierLog: @unchecked Sendable {
  static let shared = PierLog()

  /// Rotate at 512 KB and keep exactly one previous file. Pier writes a handful
  /// of lines per action, so this is weeks of history without unbounded growth
  /// in a directory the user never thinks about.
  static let maxBytes = 512 * 1024

  static var directory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Pier", isDirectory: true)
  }
  static var fileURL: URL { directory.appendingPathComponent("pier.log") }
  static var previousURL: URL { directory.appendingPathComponent("pier.log.1") }

  /// The log is an inventory of what runs on this machine — every service,
  /// container, agent-spawned process and port. Default file mode would leave
  /// that readable by every local user, so the file is 0600 and its directory
  /// 0700.
  static let fileMode: NSNumber = 0o600
  static let directoryMode: NSNumber = 0o700

  /// Serial so interleaved writes from the monitor queue and the main thread
  /// can't split a line.
  private let queue = DispatchQueue(label: "com.pier.log")
  private var enabled = true
  /// A log written before the 0600 default existed keeps its old mode, so the
  /// first write of each session tightens it.
  private var didTightenPermissions = false

  private init() {}

  /// Append one line. Never throws — logging must not be able to break the app,
  /// so a failure disables logging for the session instead of propagating.
  func log(_ message: String) {
    let line = Self.format(Self.redact(Self.singleLine(message)), at: Date())
    queue.async { [weak self] in
      guard let self, self.enabled else { return }
      do {
        try self.write(line)
      } catch {
        self.enabled = false
      }
    }
  }

  /// Block until queued writes land — used before the app exits so the final
  /// "quit" line isn't lost to an async hop.
  func flush() {
    queue.sync {}
  }

  private func write(_ line: String) throws {
    let fm = FileManager.default
    let url = Self.fileURL
    if !fm.fileExists(atPath: url.path) {
      try fm.createDirectory(
        at: Self.directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: Self.directoryMode])
      fm.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: Self.fileMode])
    } else if !didTightenPermissions {
      try? fm.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: url.path)
      try? fm.setAttributes(
        [.posixPermissions: Self.directoryMode], ofItemAtPath: Self.directory.path)
    }
    didTightenPermissions = true
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    try handle.write(contentsOf: Data(line.utf8))
    if Self.shouldRotate(size: Int(end) + line.utf8.count) {
      // `defer` above owns the close — closing here too would double-close the
      // same descriptor. Moving an open file is fine on APFS.
      try? fm.removeItem(at: Self.previousURL)
      try? fm.moveItem(at: url, to: Self.previousURL)
    }
  }

  // MARK: - Pure helpers (tested)

  static func shouldRotate(size: Int, limit: Int = maxBytes) -> Bool {
    size >= limit
  }

  /// ISO-8601 local time, so a line lines up with "what I did a minute ago"
  /// without timezone math.
  static func format(_ message: String, at date: Date) -> String {
    "\(date.formatted(isoStyle))  \(message)\n"
  }

  /// A value-type style rather than a shared `ISO8601DateFormatter`: lines are
  /// formatted on the log queue, and the formatter class isn't `Sendable`.
  /// Same output as `[.withInternetDateTime]` in the local zone, offset
  /// included (`2026-10-25T13:38:41-07:00`).
  private static let isoStyle = Date.ISO8601FormatStyle(
    timeZoneSeparator: .colon, timeZone: .current)

  /// One entry, one line: names in a message come from other processes, and a
  /// line break inside one would start a forged entry of the attacker's
  /// choosing. Backstop to `LsofParser.unescape` doing the same at the source.
  static func singleLine(_ message: String) -> String {
    // Character-level: "\r\n" is one Character, so it becomes one space.
    message.split(whereSeparator: \.isNewline).joined(separator: " ")
  }

  /// Backstop against a secret reaching the file if a caller ever logs
  /// something argv-shaped. Masks `--flag=value` / `KEY=value` where the key
  /// looks credential-ish, the same keywords in the shapes a CLI's *failure
  /// text* prints (`--password hunter2`, `token: ghp_…`, `password "hunter2"`),
  /// and `Bearer`/`Basic` scheme credentials. Over-masking a word is cheap;
  /// a leaked credential is not.
  static func redact(_ message: String) -> String {
    maskCredentialShapes(in: maskAssignments(in: message))
  }

  /// Credential keywords for the non-assignment shapes. Bare `auth` and `key`
  /// are deliberately absent — "auth failed" and "keyboard" would mask
  /// ordinary words — and `bearer`/`basic` get their own scheme rule below.
  private static let shapeKeywords = "password|passwd|secret|token|apikey|api-key|credential"

  private static func maskCredentialShapes(in text: String) -> String {
    var result = text
    func mask(_ pattern: String) {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { return }
      result = regex.stringByReplacingMatches(
        in: result, range: NSRange(result.startIndex..., in: result),
        withTemplate: "$1 ***")
    }
    let k = Self.shapeKeywords
    // A flag and its space-separated value: `--password hunter2`,
    // `--access-token ghp_…` ("token" matches with the flag prefix).
    mask("(--[A-Za-z0-9-]*(?:\(k))[A-Za-z0-9-]*)[ \\t]+(\"[^\"]*\"|'[^']*'|\\S+)")
    // A field or header: `token: ghp_…`. "token: expired" over-masks — the
    // leak it prevents is worth more than the word it hides.
    mask("(\\b(?:\(k))[ \\t]*:)[ \\t]*(\"[^\"]*\"|'[^']*'|\\S+)")
    // A bare keyword with a *quoted* value only: `password "hunter2"`. The
    // unquoted form is skipped on purpose — "token expired" is a message,
    // not a secret.
    mask("(\\b(?:\(k)))[ \\t]+(\"[^\"]*\"|'[^']*')")
    // Auth schemes, wherever they appear: `Bearer eyJ…`, `Basic dXNlcjpw…`.
    mask("\\b(bearer|basic)[ \\t]+[A-Za-z0-9._~+/=-]+")
    return result
  }

  /// Credential-ish key fragments, matched against the *normalized* key (lower
  /// case, separators stripped) so `--api-key`, `API_KEY`, and `apiKey` all hit
  /// the same rule — the hyphen form is the one that slipped through first.
  private static let secretFragments = [
    "password", "passwd", "secret", "token", "apikey", "auth", "credential",
    "bearer", "privatekey",
  ]

  /// Replaces the value in `<key>=<value>` with `***` whenever the key looks
  /// credential-ish, stopping the value at whitespace.
  private static func maskAssignments(in text: String) -> String {
    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
      guard let eq = text[index...].firstIndex(of: "=") else {
        result += text[index...]
        break
      }
      // The token immediately before '=' — the assignment's key.
      let keyStart =
        text[index..<eq].lastIndex(where: { $0 == " " || $0 == "\t" })
        .map { text.index(after: $0) } ?? index
      let key = text[keyStart..<eq].lowercased().filter { $0.isLetter || $0.isNumber }
      let valueEnd =
        text[text.index(after: eq)...].firstIndex(where: { $0 == " " || $0 == "\t" })
        ?? text.endIndex
      if secretFragments.contains(where: key.contains) {
        result += text[index...eq] + "***"
        index = valueEnd
      } else {
        result += text[index...eq]
        index = text.index(after: eq)
      }
    }
    return result
  }

  /// A tool's failure output, bounded for the log: first line only, trimmed,
  /// capped at 200 characters. Tool output is the one thing that reaches the
  /// file without a caller choosing every word, so it gets an explicit ceiling
  /// on top of `redact` — a docker error can echo an entrypoint or a mount path,
  /// and there's no reason for a whole stack of it to live on disk.
  static func summarize(_ output: String, limit: Int = 200) -> String {
    let first = output.split(separator: "\n").first.map(String.init) ?? ""
    let trimmed = first.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "(no output)" }
    return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
  }

  /// Last `lines` lines of the current log (plus the rotated one when the
  /// current file is short), for the `--tail-log` probe.
  static func tail(_ lines: Int) -> String {
    var text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    if text.split(separator: "\n").count < lines,
      let previous = try? String(contentsOf: previousURL, encoding: .utf8)
    {
      text = previous + text
    }
    let all = text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.isEmpty }
    return all.suffix(lines).joined(separator: "\n")
  }
}

extension Bundle {
  /// CFBundleShortVersionString, or "dev" when running the bare SPM executable
  /// (no bundle Info.plist), which is the normal case during development.
  var shortVersion: String {
    object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }
}
