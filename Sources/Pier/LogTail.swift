import Combine
import Foundation

/// Where a row's logs can be read from — and when they can't, why not.
///
/// Not every listener has readable output. A plain dev server writes to the
/// stdout of the terminal that launched it; nothing outside that process can
/// read it after the fact (`log stream` only sees `os_log` users, which node and
/// python aren't). Saying that plainly beats showing an empty box.
enum LogSource: Equatable {
  /// `docker logs --follow` — a real stream.
  case docker(container: String)
  /// `container logs` — read as a snapshot, since Apple's CLI has no follow.
  case appleContainer(container: String)
  /// A cmux surface's scrollback: the actual terminal output of whatever runs
  /// there, which is how a cmux-launched dev server's logs become reachable.
  case cmuxSurface(ref: String, title: String)
  /// A Terminal.app tab's scrollback, read through AppleScript by tty. Only
  /// ever read while its log panel is open — never on the refresh tick.
  case terminalTab(tty: String, title: String)
  case unavailable(reason: String)

  var isAvailable: Bool {
    if case .unavailable = self { return false }
    return true
  }

  /// Shown in the log panel's header.
  var label: String {
    switch self {
    case .docker(let container): return "docker logs \(container)"
    case .appleContainer(let container): return "container logs \(container)"
    case .cmuxSurface(_, let title): return "cmux · \(title)"
    case .terminalTab(_, let title): return "Terminal · \(title)"
    case .unavailable(let reason): return reason
    }
  }

  /// Streams keep a live pipe open; snapshots re-run on an interval.
  var isStream: Bool {
    if case .docker = self { return true }
    return false
  }

  /// Seconds between re-reads for snapshot sources.
  var pollInterval: TimeInterval { 2 }

  /// Lines requested from the source.
  static let tailLines = 300

  /// Environment for this source (carries the cmux socket password, if any).
  func environment(cmuxPassword: String?) -> [String: String] {
    guard case .cmuxSurface = self else { return [:] }
    return CmuxAccess.environment(password: cmuxPassword)
  }

  func arguments(cmuxPassword: String? = nil) -> [String] {
    switch self {
    case .docker(let container):
      return ["logs", "--tail", "\(Self.tailLines)", "--follow", container]
    case .appleContainer(let container):
      // Without -n the CLI prints the container's entire history, and this
      // runs every 2 s — the whole log materialised as one String each time.
      return ["logs", "-n", "\(Self.tailLines)", container]
    case .cmuxSurface(let ref, _):
      // Password goes in the environment, never argv — see CmuxAccess.
      return ["read-screen", "--surface", ref, "--scrollback", "--lines", "\(Self.tailLines)"]
    case .terminalTab(let tty, _):
      return TerminalSessions.historyArguments(tty: tty)
    case .unavailable:
      return []
    }
  }

  // MARK: - Resolution

  /// Background-activity rows: containers have logs, MCP servers don't — their
  /// stdio is owned by the harness that spawned them, not by a file or daemon.
  static func resolve(activity entry: ActivityEntry) -> LogSource {
    switch entry.kind {
    case .docker: return .docker(container: entry.name)
    case .apple: return .appleContainer(container: entry.name)
    case .mcp:
      return .unavailable(
        reason: "MCP servers talk over stdio to their harness — no log to read")
    case .simulator:
      return .unavailable(reason: "simulator logs live in Console.app, under the device")
    }
  }

  /// Listening ports: readable when the process runs in a cmux surface or a
  /// Terminal.app tab.
  static func resolve(port entry: PortEntry) -> LogSource {
    if let ref = entry.cmuxSurfaceRef, case .cmux(_, let surface, _) = entry.attribution {
      return .cmuxSurface(ref: ref, title: surface)
    }
    if case .terminal(let session) = entry.attribution {
      switch session.app {
      case .terminal:
        if let tty = session.tty { return .terminalTab(tty: tty, title: session.directory) }
      case .ghostty:
        // Ghostty 1.3's AppleScript names terminals but exposes no tty, pid or
        // screen contents, and its scrollback actions write to the clipboard or
        // paste into the tab. Nothing safe to read until that changes.
        return .unavailable(reason: "Ghostty doesn't let other apps read a tab's output yet")
      }
    }
    if case .system = entry.attribution {
      return .unavailable(reason: "system process — check Console.app")
    }
    return .unavailable(
      reason:
        "output goes to the terminal that started it; run it in cmux or Terminal to tail it here")
  }
}

/// Pure text handling for the tailer, kept off the main actor so it stays
/// testable and callable from a read handler.
enum LogText {
  /// Lines retained. Enough to scroll back through a stack trace without
  /// letting a chatty container grow the panel without bound.
  static let cap = 800

  /// Longest partial line held while waiting for its newline. A stream that
  /// never sends one (a progress bar, a binary blob) would otherwise grow the
  /// carry without bound; past this it's emitted as a line of its own.
  static let maxCarry = 64 * 1024

  /// Split a chunk into complete lines plus the leftover partial line — a pipe
  /// chunk can end mid-line, and joining it to the next read is what keeps a
  /// long log line from being torn in two.
  static func split(_ chunk: String, carry: String) -> (lines: [String], carry: String) {
    let combined = carry + chunk
    guard combined.contains("\n") else {
      if combined.utf8.count > maxCarry { return ([String(combined.prefix(maxCarry))], "") }
      return ([], combined)
    }
    var parts = combined.components(separatedBy: "\n")
    var remainder = parts.removeLast()  // "" when the chunk ended on a newline
    if remainder.utf8.count > maxCarry {
      parts.append(String(remainder.prefix(maxCarry)))
      remainder = ""
    }
    return (parts, remainder)
  }

  /// Append with a hard cap, dropping oldest first.
  static func appendCapped(_ existing: [String], adding: [String], cap: Int = cap) -> [String] {
    var result = existing + adding
    if result.count > cap { result.removeFirst(result.count - cap) }
    return result
  }

  /// Strip ANSI escape sequences — cmux scrollback is a rendered terminal, so it
  /// arrives full of cursor and color codes that would otherwise show as noise.
  static func stripANSI(_ line: String) -> String {
    line.replacingOccurrences(
      of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
  }
}

/// Reads a `LogSource` into a capped, live list of lines.
@MainActor
final class LogTailer: ObservableObject {
  enum State: Equatable {
    case idle
    case reading
    case ended(String?)
  }

  @Published private(set) var lines: [String] = []
  /// Running number of the first line in `lines`: grows as the cap drops old
  /// lines, so `firstLineNumber + index` is a stable identity for each line.
  /// Keyed by index alone, every line changed identity whenever one dropped
  /// off the top, and the view rebuilt all 800 rows per chunk.
  @Published private(set) var firstLineNumber = 0
  @Published private(set) var state: State = .idle

  private var process: Process?
  private var pollTimer: Timer?
  /// Partial trailing line held between reads (a pipe chunk splits anywhere).
  private var carry = ""
  private var source: LogSource = .unavailable(reason: "")
  private var toolPath: String?

  // MARK: - Lifecycle

  func start(source: LogSource, toolPath: String?, cmuxPassword: String? = nil) {
    stop()
    self.source = source
    self.toolPath = toolPath
    lines = []
    firstLineNumber = 0
    carry = ""
    guard source.isAvailable else {
      state = .ended(nil)
      return
    }
    guard let toolPath else {
      state = .ended("the CLI for this source isn't installed")
      return
    }
    state = .reading
    let environment = source.environment(cmuxPassword: cmuxPassword)
    if source.isStream {
      startStream(toolPath: toolPath, arguments: source.arguments())
    } else {
      let arguments = source.arguments()
      readSnapshot(toolPath: toolPath, arguments: arguments, environment: environment)
      let timer = Timer(timeInterval: source.pollInterval, repeats: true) { [weak self] _ in
        Task { @MainActor in
          self?.readSnapshot(toolPath: toolPath, arguments: arguments, environment: environment)
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      pollTimer = timer
    }
  }

  func stop() {
    pollTimer?.invalidate()
    pollTimer = nil
    // Clear the reader *before* terminating: a process that ignores SIGTERM
    // would keep the handler firing chunks into a drawer nobody is watching —
    // the same shape as the closed-panel CPU trap, on the streaming side.
    (process?.standardOutput.flatMap { $0 as? Pipe })?.fileHandleForReading
      .readabilityHandler = nil
    if let process, process.isRunning {
      process.terminationHandler = nil
      process.terminate()
    }
    process = nil
    if state == .reading { state = .idle }
  }

  // MARK: - Reading

  private func startStream(toolPath: String, arguments: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: toolPath)
    task.arguments = arguments
    let pipe = Pipe()
    // Container runtimes write logs to both streams; merge so nothing is lost.
    task.standardOutput = pipe
    task.standardError = pipe

    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
      Task { @MainActor in self?.ingest(chunk) }
    }
    task.terminationHandler = { [weak self] _ in
      Task { @MainActor in
        self?.finishStream()
      }
    }
    do {
      try task.run()
      process = task
    } catch {
      state = .ended("could not start: \(error.localizedDescription)")
    }
  }

  private func finishStream() {
    process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
    if !carry.isEmpty {
      append([LogText.stripANSI(carry)])
      carry = ""
    }
    process = nil
    if state == .reading { state = .ended(lines.isEmpty ? "no output" : nil) }
  }

  private func append(_ new: [String]) {
    let dropped = max(0, lines.count + new.count - LogText.cap)
    lines = LogText.appendCapped(lines, adding: new)
    firstLineNumber += dropped
  }

  private func ingest(_ chunk: String) {
    let (complete, remainder) = LogText.split(chunk, carry: carry)
    carry = remainder
    guard !complete.isEmpty else { return }
    append(complete.map(LogText.stripANSI))
  }

  private func readSnapshot(
    toolPath: String, arguments: [String], environment: [String: String] = [:]
  ) {
    let source = self.source
    // Weak from the outermost closure: a weak capture only in the inner Task
    // still let the dispatch block hold the tailer strongly for the whole run.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = ProcessRunner.run(toolPath, arguments, timeout: 8, environment: environment)
      Task { @MainActor [weak self] in
        guard let self, self.source == source else { return }
        guard let result else {
          self.state = .ended("could not run the CLI")
          return
        }
        if result.exitCode != 0, case .terminalTab = source,
          let reason = TerminalSessions.historyFailureReason(result.stderr)
        {
          self.lines = []
          self.state = .ended(reason)
          return
        }
        let text = result.stdout.isEmpty ? result.stderr : result.stdout
        let fresh = text.components(separatedBy: "\n")
          .map(LogText.stripANSI)
          .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        // Snapshots replace rather than append — the source is the current view.
        self.lines = Array(fresh.suffix(LogText.cap))
        if self.lines.isEmpty {
          self.state = .ended(result.exitCode == 0 ? "no output yet" : "unavailable")
        } else {
          self.state = .reading
        }
      }
    }
  }
}
