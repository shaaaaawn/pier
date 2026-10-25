import Darwin
import Foundation

// Ports started in a plain terminal tab — Ghostty or macOS's Terminal.
//
// Both already attributed as "Ghostty" / "Terminal" by walking the ancestor
// chain; that lumped every tab into one bucket. A tab is a session: the shell
// (or `-e` command) that the terminal starts under `/usr/bin/login`. Its tty
// tells two tabs apart and its working directory is what a person recognises a
// tab by, so ports group per tab the way cmux ports group per workspace.
//
// Both facts come from libproc for the session leader alone — a few
// microseconds per terminal-attributed port, no subprocess, no permission.

/// The terminals Pier knows how to split into tabs.
enum TerminalApp: String, Equatable, Sendable {
  case ghostty
  case terminal

  /// Exact `ucomm` match. The harness table's word-boundary match would also
  /// accept `terminal-notifier`, which is not a terminal anyone types into.
  init?(processName: String) {
    switch processName.lowercased() {
    case "ghostty": self = .ghostty
    case "terminal": self = .terminal
    default: return nil
    }
  }

  /// Same label the harness table uses, so the fallback reads identically.
  var label: String {
    switch self {
    case .ghostty: return "Ghostty"
    case .terminal: return "Terminal"
    }
  }
}

/// What libproc reports about a session leader.
struct TerminalSessionInfo: Equatable, Sendable {
  /// "ttys012", as `ps` prints it; nil when the process has no terminal.
  var tty: String?
  /// Absolute working directory.
  var directory: String?
}

/// One terminal tab, as far as Pier can see it.
struct TerminalSession: Equatable, Sendable {
  let app: TerminalApp
  /// Display form of the tab's working directory ("~/code/app").
  let directory: String
  let tty: String?

  var title: String { "\(app.label) · \(directory)" }
}

enum TerminalSessions {
  /// The tab a process runs in, from its ancestor chain (self first).
  ///
  /// The terminal starts `login`, which starts the shell — or, for
  /// `ghostty -e cmd`, the command itself. That child of `login` is the
  /// session leader. nil when no terminal is in the chain, or when the chain
  /// stops at the terminal itself.
  static func leader(in chain: [ProcessTable.Proc]) -> (app: TerminalApp, pid: Int32)? {
    guard let k = chain.firstIndex(where: { TerminalApp(processName: $0.name) != nil }),
      let app = TerminalApp(processName: chain[k].name), k >= 1
    else { return nil }
    let below = chain[k - 1]
    if below.name == "login", k >= 2 { return (app, chain[k - 2].pid) }
    return (app, below.pid)
  }

  static func session(
    app: TerminalApp, info: TerminalSessionInfo?, home: String = NSHomeDirectory()
  ) -> TerminalSession? {
    guard let directory = info?.directory, !directory.isEmpty else { return nil }
    return TerminalSession(
      app: app, directory: displayPath(directory, home: home), tty: info?.tty)
  }

  /// "~/code/app"; deep paths keep the last two components ("…/web/api"),
  /// which is what tells two projects apart in a 340pt header.
  static func displayPath(_ path: String, home: String) -> String {
    var shown = path
    if path == home {
      return "~"
    } else if path.hasPrefix(home + "/") {
      shown = "~" + path.dropFirst(home.count)
    }
    let parts = shown.split(separator: "/", omittingEmptySubsequences: true)
    let root = shown.hasPrefix("~") ? 1 : 0
    guard parts.count - root > 3 else { return shown }
    return "…/" + parts.suffix(2).joined(separator: "/")
  }

  // MARK: - libproc

  /// tty and working directory for one pid, read in-process. Same user only,
  /// which is all a terminal tab ever is.
  nonisolated static func read(pid: Int32) -> TerminalSessionInfo? {
    var info = TerminalSessionInfo()

    var bsd = proc_bsdinfo()
    let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize {
      info.tty = ttyName(device: bsd.e_tdev)
    }

    var vnode = proc_vnodepathinfo()
    let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize {
      info.directory = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
      }
    }
    return info.tty == nil && info.directory == nil ? nil : info
  }

  /// "ttys012" for a controlling-terminal device; nil for NODEV (no tty).
  static func ttyName(device: UInt32) -> String? {
    guard device != UInt32.max, device != 0 else { return nil }
    guard let name = devname(dev_t(bitPattern: device), S_IFCHR) else { return nil }
    return String(cString: name)
  }

  // MARK: - Terminal.app scrollback

  /// AppleScript that prints one Terminal tab's scrollback, found by tty.
  /// Fixed text: the tty arrives as `argv`, never spliced into the source. It
  /// checks `is running` first so a stale row can't launch Terminal.
  static let historyScript = [
    "on run argv",
    "if application \"Terminal\" is not running then return \"\"",
    "set target to \"/dev/\" & item 1 of argv",
    "tell application \"Terminal\"",
    "repeat with w in windows",
    "repeat with t in tabs of w",
    "if tty of t is target then return history of t",
    "end repeat",
    "end repeat",
    "end tell",
    "return \"\"",
    "end run",
  ]

  /// `osascript -e … -e … <tty>`.
  static func historyArguments(tty: String) -> [String] {
    historyScript.flatMap { ["-e", $0] } + [tty]
  }

  /// osascript's failure text → what to tell the person, or nil to show it raw.
  static func historyFailureReason(_ stderr: String) -> String? {
    if stderr.contains("-1743") {
      return "Pier isn't allowed to read Terminal yet — allow it in System Settings → "
        + "Privacy & Security → Automation"
    }
    if stderr.contains("-600") { return "Terminal isn't running" }
    return nil
  }
}
