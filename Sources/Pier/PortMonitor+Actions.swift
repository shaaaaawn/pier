import AppKit
import Combine
import Foundation

// Split out of PortMonitor.swift, which mixed three unrelated jobs in one
// 640-line file: probing the world, assembling rows, and acting on them.
//
// Stored properties stay on the class — Swift extensions can't declare them,
// and `@Published` needs storage — so only behaviour moved. Members crossed by
// the split are module-internal as a result; see PortListView's split for the
// same trade.

// Everything that changes the machine: kill, start, stop, prune, disk usage.
extension PortMonitor {
  // MARK: - Actions

  /// Whether a pid may be signalled at all. `kill()` gives non-positive pids
  /// special meanings: 0 is our own process group, and **-1 is every process
  /// this user owns** — `kill(-1, SIGKILL)` would take down every app on the
  /// desktop. pid 1 is launchd. No probe produces these today (`ps -ax` omits
  /// pid 0, lsof reports real pids), but `Int32("-1")` parses happily, so one
  /// malformed line away from a disaster is not a margin worth keeping.
  nonisolated static func isSignalable(_ pid: Int32) -> Bool {
    pid > 1
  }

  /// The process started at `expected` (from the row) is the one now at `pid`.
  /// No recorded start (fixtures, probes) passes; a pid that's gone fails.
  nonisolated static func isSameProcess(expected: UInt64?, current: UInt64?) -> Bool {
    guard let expected else { return true }
    return current == expected
  }

  /// Start time of `pid` in µs since the epoch, from libproc. Unforgeable by
  /// the process itself, unlike its name.
  nonisolated static func startTime(of pid: Int32) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
  }

  /// `expectedStart` is the row's `startTime`. Pass it whenever the pid came
  /// from a row: rows can be up to 30 s old, and signalling a recycled pid
  /// would kill — and with the follow-up prompt, SIGKILL — an unrelated
  /// process while the dialog still names the old one.
  func terminate(_ pid: Int32, force: Bool = false, expectedStart: UInt64? = nil) {
    guard Self.isSignalable(pid) else {
      PierLog.shared.log("refused to signal pid \(pid): not a real process id")
      return
    }
    guard Self.isSameProcess(expected: expectedStart, current: Self.startTime(of: pid)) else {
      PierLog.shared.log("refused to signal pid \(pid): a different process holds it now")
      refresh()
      return
    }
    PierLog.shared.log("kill pid \(pid) with \(force ? "SIGKILL" : "SIGTERM")")
    // One pid can hold several ports; each becomes its own stop event.
    for entry in entries where entry.pid == pid {
      expect(.stopped, subject: .port(entry.port, process: entry.processName))
    }
    kill(pid, force ? SIGKILL : SIGTERM)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.refresh()
    }
  }

  /// "Stop All" for detached dev servers: one SIGTERM per process (a server
  /// can hold several ports), each behind the same identity check as a
  /// single kill, so a pid that changed hands since the list was read is
  /// left alone. `terminate` records the expected stops, so they read "you".
  func stopDetached(_ entries: [PortEntry]) {
    var seen: Set<Int32> = []
    for entry in entries where seen.insert(entry.pid).inserted {
      terminate(entry.pid, expectedStart: entry.startTime)
    }
  }

  /// Run a Docker lifecycle or prune action, then refresh so the panel reflects
  /// the result. Output is surfaced on failure — a prune that can't run should
  /// say why rather than look like nothing happened.
  func run(_ action: DockerAction, completion: (@MainActor (Bool, String) -> Void)? = nil) {
    guard let dockerPath else {
      completion?(false, "The docker CLI isn't installed.")
      return
    }
    PierLog.shared.log("docker action: \(action.rawValue)")
    run(tool: dockerPath, arguments: action.arguments, timeout: action.timeout) { ok, message in
      PierLog.shared.log(
        "docker \(action.rawValue): \(ok ? "ok" : "FAILED — \(PierLog.summarize(message))")")
      completion?(ok, message)
    }
  }

  /// Apple `container` equivalent.
  func run(_ action: AppleAction, completion: (@MainActor (Bool, String) -> Void)? = nil) {
    guard let containerPath else {
      completion?(false, "Apple's container CLI isn't installed.")
      return
    }
    PierLog.shared.log("apple action: \(action.rawValue)")
    run(tool: containerPath, arguments: action.arguments, timeout: action.timeout) { ok, message in
      PierLog.shared.log(
        "apple \(action.rawValue): \(ok ? "ok" : "FAILED — \(PierLog.summarize(message))")")
      completion?(ok, message)
    }
  }

  private func run(
    tool: String, arguments: [String], timeout: TimeInterval,
    completion: (@MainActor (Bool, String) -> Void)? = nil
  ) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = ProcessRunner.run(tool, arguments, timeout: timeout)
      DispatchQueue.main.async {
        let ok = result?.exitCode == 0
        let text = (result?.combined ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        completion?(ok, text.isEmpty ? (ok ? "Done." : "Failed.") : text)
        self?.refresh()
        self?.refreshDockerDiskUsage()
        self?.refreshAppleDiskUsage()
      }
    }
  }

  /// `docker system df` — read-only, so it can run on every panel open to keep
  /// the prune confirmation honest about what it would reclaim.
  /// `container system df`, same idea as Docker's.
  func refreshAppleDiskUsage() {
    guard let containerPath, appleState.isReady else {
      appleReclaimable = nil
      return
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let result = ProcessRunner.run(containerPath, ["system", "df"], timeout: 12)
      let summary = result.flatMap { output -> String? in
        guard output.exitCode == 0 else { return nil }
        return AppleControl.reclaimableSummary(AppleControl.parseDiskUsage(output.stdout))
      }
      DispatchQueue.main.async { self?.appleReclaimable = summary }
    }
  }

  func refreshDockerDiskUsage() {
    guard let dockerPath, dockerState.isReady else {
      dockerReclaimable = nil
      return
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let result = ProcessRunner.run(dockerPath, ["system", "df"], timeout: 10)
      let summary = result.flatMap { output -> String? in
        guard output.exitCode == 0 else { return nil }
        return DockerControl.reclaimableSummary(DockerControl.parseDiskUsage(output.stdout))
      }
      DispatchQueue.main.async { self?.dockerReclaimable = summary }
    }
  }

  /// Start a stopped container (`docker start` / `container start`).
  func start(_ entry: ActivityEntry) {
    let path = entry.kind == .docker ? dockerPath : containerPath
    // Only booted simulators are listed, so there is never one to start.
    guard let path, entry.kind == .docker || entry.kind == .apple else { return }
    PierLog.shared.log("start \(entry.kind.rawValue) container \(entry.name)")
    expect(.started, subject: .container(entry.kind, entry.name))
    run(tool: path, arguments: ["start", entry.name], timeout: 60) { ok, message in
      PierLog.shared.log(
        "start \(entry.name): \(ok ? "ok" : "FAILED — \(PierLog.summarize(message))")")
    }
  }

  /// Stop an activity row: SIGTERM every pid for MCP rows, `docker stop` /
  /// `container stop` for container rows, `simctl shutdown` for simulators.
  func stop(_ entry: ActivityEntry) {
    switch entry.kind {
    case .mcp:
      PierLog.shared.log("kill \(entry.pids.count) pid(s) for MCP row \(entry.name)")
      expect(.stopped, subject: .mcp(entry.name))
      for pid in entry.pids {
        guard Self.isSignalable(pid) else {
          PierLog.shared.log("refused to signal pid \(pid): not a real process id")
          continue
        }
        kill(pid, SIGTERM)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    case .docker, .apple:
      let path = entry.kind == .docker ? dockerPath : containerPath
      guard let path else { return }
      PierLog.shared.log("stop \(entry.kind.rawValue) container \(entry.name)")
      expect(.stopped, subject: .container(entry.kind, entry.name))
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let result = ProcessRunner.run(path, ["stop", entry.name], timeout: 20)
        PierLog.shared.log(
          "stop \(entry.name): exit \(result?.exitCode.description ?? "timeout")")
        DispatchQueue.main.async { self?.refresh() }
      }
    case .simulator:
      guard let ref = entry.simulator else { return }
      PierLog.shared.log("shut down simulator \(entry.name)")
      expect(.stopped, subject: .container(.simulator, entry.name))
      runSimctl(SimulatorParser.shutdownArguments(ref), label: entry.name)
    }
  }

  /// Shut down every booted simulator Pier lists. One `shutdown all` per
  /// device set, so XCTest clones go too — they hold just as much memory.
  func shutDownAllSimulators() {
    let booted = activity.filter { $0.kind == .simulator && $0.simulator != nil }
    for entry in booted {
      expect(.stopped, subject: .container(.simulator, entry.name))
    }
    let sets = Set(booted.compactMap { $0.simulator?.deviceSet })
    PierLog.shared.log("shut down all simulators (\(booted.count) booted)")
    for set in sets.sorted() {
      runSimctl(SimulatorParser.shutdownAllArguments(deviceSet: set), label: "all")
    }
  }

  /// `xcrun simctl …` off the main thread. Shutdown waits for the device to
  /// finish stopping, which takes a few seconds, hence the generous timeout.
  private func runSimctl(_ arguments: [String], label: String) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = ProcessRunner.run("/usr/bin/xcrun", arguments, timeout: 60)
      PierLog.shared.log(
        "simctl shutdown \(label): exit \(result?.exitCode.description ?? "timeout")")
      DispatchQueue.main.async { self?.refresh() }
    }
  }

  func isAlive(_ pid: Int32, expectedStart: UInt64? = nil) -> Bool {
    // kill(0/-1, 0) "succeeds" for the process group / every process, which
    // would report a pid that never existed as alive.
    // And alive means *the same* process: a recycled pid isn't "still running".
    Self.isSignalable(pid) && kill(pid, 0) == 0
      && Self.isSameProcess(expected: expectedStart, current: Self.startTime(of: pid))
  }

  /// Full command line for hover tooltips, cached per pid.
  func commandLine(for pid: Int32, completion: @escaping @MainActor (String) -> Void) {
    if let cached = commandCache[pid] {
      completion(cached)
      return
    }
    DispatchQueue.global().async {
      let output =
        ProcessRunner.run("/bin/ps", ["-p", "\(pid)", "-o", "command="], timeout: 3)?
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      DispatchQueue.main.async {
        if !output.isEmpty { self.commandCache[pid] = output }
        completion(output.isEmpty ? "pid \(pid)" : output)
      }
    }
  }
}
