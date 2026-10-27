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

// Docker / Apple Containers / MCP collection, and the CLI snapshot probe.
extension PortMonitor {
  /// pid → full command line, from `ps -axo pid=,user=,command=`.
  nonisolated static func parseCommands(_ output: String) -> [Int32: String] {
    var map: [Int32: String] = [:]
    for line in output.split(separator: "\n") {
      if let (pid, command) = commandLine(line) { map[pid] = command }
    }
    return map
  }

  /// One `pid user command…` line → (pid, command), with the command's
  /// whitespace collapsed to single spaces, exactly as splitting on spaces/tabs
  /// and re-joining always produced.
  ///
  /// Fast path: `ps` almost never puts tabs or doubled spaces inside a command,
  /// and in that case the remainder already *is* the re-joined string. The old
  /// split-and-join built an array of every token of every process — ~1,000
  /// lines, some over 9,000 characters — and was ~13 ms of every refresh.
  /// No tab, no two spaces in a row, no trailing space — checked on bytes,
  /// because walking ~9 KB as Characters (grapheme segmentation) cost more than
  /// the split it was meant to avoid. Byte-clean implies the Character-level
  /// split-and-join reproduces the text verbatim: its separators are exactly the
  /// " " and "\t" Characters, which need those bytes.
  nonisolated static func isSingleSpaced(_ text: Substring) -> Bool {
    var previousWasSpace = false
    for byte in text.utf8 {
      if byte == 0x09 { return false }
      if byte == 0x20 {
        if previousWasSpace { return false }
        previousWasSpace = true
      } else {
        previousWasSpace = false
      }
    }
    return !previousWasSpace
  }

  nonisolated static func commandLine(_ line: Substring) -> (Int32, String)? {
    let isSpace = { (c: Character) in c == " " || c == "\t" }
    let afterLead = line.drop(while: isSpace)
    let pidToken = afterLead.prefix(while: { !isSpace($0) })
    let afterPid = afterLead.dropFirst(pidToken.count).drop(while: isSpace)
    let userToken = afterPid.prefix(while: { !isSpace($0) })
    let rest = afterPid.dropFirst(userToken.count).drop(while: isSpace)
    guard !userToken.isEmpty, !rest.isEmpty, let pid = Int32(pidToken) else { return nil }
    if isSingleSpaced(rest) { return (pid, String(rest)) }
    let tokens = rest.split(whereSeparator: isSpace)
    return (pid, tokens.joined(separator: " "))
  }

  /// Background activity: docker + apple containers + MCP processes.
  /// Every section degrades to empty when its CLI is missing or its daemon
  /// is down (non-zero exit → skipped below).
  nonisolated static func collectActivity(
    dockerPath: String?, containerPath: String?, table: ProcessTable, cmux: CmuxSnapshot?,
    commandsOutput: String? = nil, commands: [Int32: String]? = nil
  ) -> (
    entries: [ActivityEntry], dockerState: EngineState, dockerFault: DockerControl.Fault?,
    appleState: EngineState
  ) {
    var activity: [ActivityEntry] = []
    var dockerState = EngineState.cliMissing
    // Returned with the rest of the snapshot, never parked in a static: this
    // runs on the refresh queue and the panel reads it on main, which is the
    // race 939846e removed for the engine states themselves.
    var dockerFault: DockerControl.Fault?
    if let dockerPath {
      let result = ProcessRunner.run(
        dockerPath,
        ["ps", "-a", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"],
        timeout: 5)
      dockerState = DockerControl.state(from: result, cliInstalled: true)
      dockerFault = DockerControl.fault(from: result, cliInstalled: true)
      if dockerState.isReady, let result {
        activity += ActivityParser.parseDockerPS(result.stdout)
      }
    }
    var appleState = EngineState.cliMissing
    if let containerPath {
      let result = ProcessRunner.run(containerPath, ["list", "--all"], timeout: 8)
      appleState = AppleControl.state(from: result, cliInstalled: true)
      if appleState.isReady, let result {
        activity += ActivityParser.parseContainerList(result.stdout)
      }
    }
    let fullPS =
      commandsOutput
      ?? ProcessRunner.run("/bin/ps", ["-axo", "pid=,user=,command="], timeout: 5)?.stdout ?? ""
    activity += ActivityParser.mcpEntries(fullPS: fullPS, table: table, cmux: cmux)
    // Free: read off the process table and command lines already in hand.
    activity += SimulatorParser.entries(
      table: table, commands: commands ?? parseCommands(fullPS))
    return (
      entries: activity, dockerState: dockerState, dockerFault: dockerFault,
      appleState: appleState
    )
  }

  /// `Pier --print-activity`: one synchronous collection pass, printed as
  /// text. Lets the detectors be verified live without opening the panel.
  nonisolated static func printActivitySnapshot() {
    // Same columns as a live refresh, so rows carry the usage the panel shows.
    let psOut =
      ProcessRunner.run("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,rss=,ucomm="], timeout: 5)?.stdout
      ?? ""
    let snapshot = collectActivity(
      dockerPath: resolveBinary(
        "docker", candidates: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]),
      containerPath: resolveBinary(
        "container", candidates: ["/usr/local/bin/container", "/opt/homebrew/bin/container"]),
      table: ProcessTable.parse(psOut),
      cmux: nil)
    for kind in [ActivityKind.docker, .apple, .simulator, .mcp] {
      let entries = snapshot.entries.filter { $0.kind == kind }
      print("\(kind.sectionTitle): \(entries.isEmpty ? "(none)" : "")")
      for e in entries {
        let count = e.count > 1 ? " ×\(e.count)" : ""
        let ports = e.ports.isEmpty ? "" : " → \(e.ports.map(String.init).joined(separator: ","))"
        let badge = e.attribution == .none ? "" : "  [\(e.attribution.badgeLabel)]"
        let usage = e.usage.map { "  (\($0.memoryLabel), \($0.cpuLabel) CPU)" } ?? ""
        print("  • \(e.name)\(count)\(ports)\(badge)\(usage)")
        if let subtitle = e.subtitle { print("      \(subtitle)") }
        if !e.detail.isEmpty { print("      \(e.detail)") }
      }
    }
  }

  /// Background-activity sections (Docker, Containers, MCP), search-filtered,
  /// in fixed kind order after the port groups.
  func activityGroups(matching query: String, filter: PierFilter = .all) -> [ActivityGroup] {
    var installed: Set<ActivityKind> = []
    if dockerState != .cliMissing { installed.insert(.docker) }
    if appleState != .cliMissing { installed.insert(.apple) }
    return Self.activityGroups(
      activity: activity, matching: query, filter: filter, installedEngines: installed)
  }

  /// Sections for the background-activity kinds.
  ///
  /// An installed **engine keeps its section even with no containers**, because
  /// the section header is where its Start/Stop/prune menu lives — drop the empty
  /// section and a ready-but-idle Docker becomes unreachable from the UI, with no
  /// way to stop it or reclaim disk. MCP has no controls, so it stays hidden when
  /// empty, and a search hides empty sections too (an empty result is the answer).
  nonisolated static func activityGroups(
    activity: [ActivityEntry], matching query: String, filter: PierFilter,
    installedEngines: Set<ActivityKind>
  ) -> [ActivityGroup] {
    filter.activityKinds.compactMap { kind in
      let entries =
        activity
        .filter { $0.kind == kind && $0.matches(query) }
        .sorted { a, b in
          // Running first: a stopped container is a thing you might start, not
          // something demanding attention.
          a.isRunning != b.isRunning ? a.isRunning : a.name < b.name
        }
      if !entries.isEmpty { return ActivityGroup(kind: kind, entries: entries) }
      guard query.isEmpty, kind != .mcp, installedEngines.contains(kind) else { return nil }
      return ActivityGroup(kind: kind, entries: [])
    }
  }
}
