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
  static func parseCommands(_ output: String) -> [Int32: String] {
    var map: [Int32: String] = [:]
    for line in output.split(separator: "\n") {
      let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard tokens.count >= 3, let pid = Int32(tokens[0]) else { continue }
      map[pid] = tokens.dropFirst(2).joined(separator: " ")
    }
    return map
  }

  /// Background activity: docker + apple containers + MCP processes.
  /// Every section degrades to empty when its CLI is missing or its daemon
  /// is down (non-zero exit → skipped below).
  static func collectActivity(
    dockerPath: String?, containerPath: String?, table: ProcessTable, cmux: CmuxSnapshot?,
    commandsOutput: String? = nil
  ) -> (entries: [ActivityEntry], dockerState: EngineState, appleState: EngineState) {
    var activity: [ActivityEntry] = []
    var dockerState = EngineState.cliMissing
    if let dockerPath {
      let result = ProcessRunner.run(
        dockerPath,
        ["ps", "-a", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"],
        timeout: 5)
      dockerState = DockerControl.state(from: result, cliInstalled: true)
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
    return (entries: activity, dockerState: dockerState, appleState: appleState)
  }

  /// `Pier --print-activity`: one synchronous collection pass, printed as
  /// text. Lets the detectors be verified live without opening the panel.
  static func printActivitySnapshot() {
    let psOut =
      ProcessRunner.run("/bin/ps", ["-axo", "pid=,ppid=,ucomm="], timeout: 5)?.stdout ?? ""
    let snapshot = collectActivity(
      dockerPath: resolveBinary(
        "docker", candidates: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]),
      containerPath: resolveBinary(
        "container", candidates: ["/usr/local/bin/container", "/opt/homebrew/bin/container"]),
      table: ProcessTable.parse(psOut),
      cmux: nil)
    for kind in [ActivityKind.docker, .apple, .mcp] {
      let entries = snapshot.entries.filter { $0.kind == kind }
      print("\(kind.sectionTitle): \(entries.isEmpty ? "(none)" : "")")
      for e in entries {
        let count = e.count > 1 ? " ×\(e.count)" : ""
        let ports = e.ports.isEmpty ? "" : " → \(e.ports.map(String.init).joined(separator: ","))"
        let badge = e.attribution == .none ? "" : "  [\(e.attribution.badgeLabel)]"
        print("  • \(e.name)\(count)\(ports)\(badge)")
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
  static func activityGroups(
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
