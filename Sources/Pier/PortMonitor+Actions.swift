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

  func terminate(_ pid: Int32, force: Bool = false) {
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

  /// Run a Docker lifecycle or prune action, then refresh so the panel reflects
  /// the result. Output is surfaced on failure — a prune that can't run should
  /// say why rather than look like nothing happened.
  func run(_ action: DockerAction, completion: ((Bool, String) -> Void)? = nil) {
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
  func run(_ action: AppleAction, completion: ((Bool, String) -> Void)? = nil) {
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
    completion: ((Bool, String) -> Void)? = nil
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
    guard let path, entry.kind != .mcp else { return }
    PierLog.shared.log("start \(entry.kind.rawValue) container \(entry.name)")
    expect(.started, subject: .container(entry.kind, entry.name))
    run(tool: path, arguments: ["start", entry.name], timeout: 60) { ok, message in
      PierLog.shared.log(
        "start \(entry.name): \(ok ? "ok" : "FAILED — \(PierLog.summarize(message))")")
    }
  }

  /// Stop an activity row: SIGTERM every pid for MCP rows, `docker stop` /
  /// `container stop` for container rows.
  func stop(_ entry: ActivityEntry) {
    switch entry.kind {
    case .mcp:
      PierLog.shared.log("kill \(entry.pids.count) pid(s) for MCP row \(entry.name)")
      expect(.stopped, subject: .mcp(entry.name))
      for pid in entry.pids { kill(pid, SIGTERM) }
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
    }
  }

  func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
  }

  /// Full command line for hover tooltips, cached per pid.
  func commandLine(for pid: Int32, completion: @escaping (String) -> Void) {
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
