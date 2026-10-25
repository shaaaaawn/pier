import Foundation

/// Whether Pier can actually talk to cmux, and why not when it can't.
///
/// cmux's socket defaults to `socketControlMode: "cmuxOnly"`, which accepts
/// connections **only from processes started inside cmux**. Pier is launched by
/// LaunchServices, so every call is refused with "Access denied". Previously
/// that looked identical to "cmux isn't installed": ports simply never grouped
/// by workspace and nothing said why.
enum CmuxStatus: Equatable {
  case notInstalled
  /// Installed but not open — no socket to talk to. Silent, like
  /// `notInstalled`: there's nothing to group, and nothing for the user to fix.
  case notRunning
  /// cmux is there but its socket is in `cmuxOnly` mode (or the password is wrong).
  case accessDenied
  case failed(String)
  case connected(workspaces: Int)

  /// One-line explanation for the panel, nil when there's nothing to say.
  var hint: String? {
    switch self {
    case .notInstalled, .notRunning, .connected: return nil
    case .accessDenied:
      return CmuxAccess.deniedHint(configuredMode: CmuxAccess.configuredMode())
    case .failed(let why): return "cmux unavailable — \(why)"
    }
  }

  var detail: String? {
    switch self {
    case .accessDenied:
      return CmuxAccess.deniedDetail(configuredMode: CmuxAccess.configuredMode())
    case .failed(let why): return why
    case .notInstalled, .notRunning, .connected: return nil
    }
  }
}

/// Reads cmux's own config for socket auth.
enum CmuxAccess {
  static var configPath: String {
    (NSHomeDirectory() as NSString).appendingPathComponent(".config/cmux/cmux.json")
  }

  /// Strip `//` line comments, honoring string literals so a `//` inside a
  /// value (a URL, say) isn't treated as a comment.
  ///
  /// This is not a nicety. cmux ships its config with a large commented-out
  /// example block that *contains* `"socketControlMode": "allowAll"`. A plain
  /// regex over the raw file matches that example and concludes the socket is
  /// already open — which is exactly the wrong answer, and produced a banner
  /// telling the user to restart cmux when the real setting was never set.
  static func stripComments(_ text: String) -> String {
    var output = ""
    output.reserveCapacity(text.count)
    var inString = false
    var escaped = false
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if escaped {
        output.append(character)
        escaped = false
        index = text.index(after: index)
        continue
      }
      if character == "\\", inString {
        output.append(character)
        escaped = true
        index = text.index(after: index)
        continue
      }
      if character == "\"" {
        inString.toggle()
        output.append(character)
        index = text.index(after: index)
        continue
      }
      if !inString, character == "/" {
        let next = text.index(after: index)
        if next < text.endIndex, text[next] == "/" {
          // Skip to the end of the line, keeping the newline for line numbers.
          while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
          continue
        }
      }
      output.append(character)
      index = text.index(after: index)
    }
    return output
  }

  /// cmux.json permits comments, so `JSONSerialization` rejects it — pull the
  /// two fields we need by pattern instead of parsing the whole document.
  private static func stringValue(_ key: String, in text: String) -> String? {
    guard
      let range = text.range(
        of: "\"\(key)\"\\s*:\\s*\"([^\"]*)\"", options: .regularExpression)
    else { return nil }
    let fragment = String(text[range])
    guard let valueRange = fragment.range(of: "\"([^\"]*)\"\\s*$", options: .regularExpression)
    else { return nil }
    return String(fragment[valueRange]).trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }

  static func parseConfig(_ text: String) -> (mode: String?, password: String?) {
    let live = stripComments(text)
    return (stringValue("socketControlMode", in: live), stringValue("socketPassword", in: live))
  }

  /// The saved socket password, when one is set. Passed to the CLI so Pier can
  /// connect once the user opens the socket up.
  /// Two very different situations produce the same refusal, so they get
  /// different advice. Pure functions of the *configured* mode, because the
  /// live cmux honors whatever it read at launch.
  static func deniedHint(configuredMode: String?) -> String {
    configuredMode == "allowAll"
      ? "cmux is configured for access but still refusing"
      : "cmux is running but blocking outside access"
  }

  static func deniedDetail(configuredMode: String?) -> String {
    if configuredMode == "allowAll" {
      return """
        ~/.config/cmux/cmux.json allows outside access, but cmux is still \
        refusing. cmux normally picks this up without a restart, so check that \
        the setting is in a real "automation" block and not inside the large \
        commented-out example block that ships in that file — editing the \
        commented copy changes nothing.

        If it is set correctly, restarting cmux is the next thing to try.
        """
    }
    return """
      cmux's socket is set to cmuxOnly, which only accepts connections from \
      processes started inside cmux — so Pier can't read workspaces, and ports \
      can't be grouped by them.

      To enable: set "socketControlMode": "allowAll" in ~/.config/cmux/cmux.json \
      (optionally with a "socketPassword", which Pier picks up automatically), \
      then restart cmux.
      """
  }

  /// `socketControlMode` as written in the config file (not what the running
  /// cmux is honoring — those can differ until it restarts).
  static func configuredMode() -> String? {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
    return parseConfig(text).mode
  }

  static func socketPassword() -> String? {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
    let password = parseConfig(text).password
    return (password?.isEmpty ?? true) ? nil : password
  }

  /// The socket password's environment variable. cmux checks `--password`
  /// first, then this, then its Settings value.
  static let passwordEnvironmentKey = "CMUX_SOCKET_PASSWORD"

  /// Arguments never carry the password: `ps` output is world-readable on macOS,
  /// so `--password <secret>` would expose the user's cmux socket password to
  /// every local process — including the ones Pier itself lists. It goes in the
  /// environment instead (see `environment(password:)`).
  static func arguments(password: String? = nil) -> [String] {
    ["top", "--all", "--processes", "--flat", "--format", "tsv"]
  }

  static func environment(password: String?) -> [String: String] {
    guard let password, !password.isEmpty else { return [:] }
    return [passwordEnvironmentKey: password]
  }

  static func isAccessDenied(_ output: String) -> Bool {
    output.localizedCaseInsensitiveContains("access denied")
  }

  /// Classify one `cmux top` invocation.
  /// The CLI's own words when no cmux instance is listening (verbatim:
  /// "Error: No live cmux socket found. Tried: …", exit 1).
  static func isNotRunning(_ output: String) -> Bool {
    output.localizedCaseInsensitiveContains("no live cmux socket")
  }

  static func status(from result: ProcessRunner.Result?, snapshotWorkspaces: () -> Int)
    -> CmuxStatus
  {
    guard let result else { return .failed("could not launch the cmux CLI") }
    if isAccessDenied(result.combined) { return .accessDenied }
    // cmux simply isn't open. Showing "cmux unavailable — Error: No live cmux
    // socket found" for that was noise: grouping by workspace is a bonus, and
    // its absence is not something to fix. Denied access still warns, because
    // then cmux *is* running and the user can open the socket.
    if isNotRunning(result.combined) { return .notRunning }
    guard result.exitCode == 0 else {
      let message = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
      return .failed(message.isEmpty ? "exited \(result.exitCode)" : String(message.prefix(120)))
    }
    return .connected(workspaces: snapshotWorkspaces())
  }
}
