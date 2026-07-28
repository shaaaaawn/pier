import Foundation

/// Snapshot of the process table, used for ancestor-chain walks and per-row
/// resource usage.
///
/// Two input shapes are accepted so the usage columns are additive:
///   `pid ppid ucomm`                — chain only (older callers, fixtures)
///   `pid ppid %cpu rss ucomm`       — chain + usage (`PortMonitor`'s probe)
/// The second is detected by the 3rd/4th fields parsing as numbers, which
/// keeps one `ps` call serving both jobs instead of spawning a second.
struct ProcessTable {
  struct Proc {
    let pid: Int32
    let ppid: Int32
    let name: String
    /// Percent of one core, as `ps` reports it (may exceed 100 on multicore).
    var cpu: Double = 0
    /// Resident set size in KB.
    var rssKB: Int = 0
  }

  let byPid: [Int32: Proc]

  static func parse(_ output: String) -> ProcessTable {
    var byPid: [Int32: Proc] = [:]
    for line in output.split(separator: "\n") {
      let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard tokens.count >= 3,
            let pid = Int32(tokens[0]),
            let ppid = Int32(tokens[1]) else { continue }
      // ucomm can contain spaces ("Google Chrome H"), so the name is always
      // the remainder of the line, never just one token.
      if tokens.count >= 5, let cpu = Double(tokens[2]), let rss = Int(tokens[3]) {
        byPid[pid] = Proc(
          pid: pid, ppid: ppid, name: tokens[4...].joined(separator: " "),
          cpu: cpu, rssKB: rss)
      } else {
        byPid[pid] = Proc(pid: pid, ppid: ppid, name: tokens[2...].joined(separator: " "))
      }
    }
    return ProcessTable(byPid: byPid)
  }

  /// Usage reading for a pid, or nil when it isn't in the table (exited, or
  /// the probe ran without the usage columns).
  func usage(for pid: Int32) -> Usage? {
    guard let proc = byPid[pid] else { return nil }
    return Usage(cpu: proc.cpu, rssKB: proc.rssKB)
  }

  /// Summed usage across pids — an MCP row groups several processes under one
  /// label, and what matters is what the group costs in total.
  func usage(for pids: [Int32]) -> Usage? {
    let procs = pids.compactMap { byPid[$0] }
    guard !procs.isEmpty else { return nil }
    return Usage(
      cpu: procs.reduce(0) { $0 + $1.cpu },
      rssKB: procs.reduce(0) { $0 + $1.rssKB })
  }

  /// Chain from `pid` upward: [self, parent, grandparent, ...], capped and cycle-safe.
  func chain(from pid: Int32, maxDepth: Int = 32) -> [Proc] {
    var result: [Proc] = []
    var seen: Set<Int32> = []
    var current = pid
    while let proc = byPid[current], !seen.contains(current), result.count < maxDepth {
      seen.insert(current)
      result.append(proc)
      if proc.ppid <= 1 { break }
      current = proc.ppid
    }
    return result
  }
}

/// Parsed `cmux top --all --processes --flat --format tsv` output.
///
/// TSV columns: cpu, memBytes, nprocs, kind, ref-or-pid, parent-ref-or-pid, name.
/// - workspace rows: ref `workspace:N`, parent `window:M`, name = workspace title
/// - surface rows:   ref `surface:N`,  parent `pane:M`,    name = surface title
/// - process rows:   ref = PID,        parent = `surface:N` or parent PID
struct CmuxSnapshot {
  /// surface ref ("surface:19") -> surface title ("Kimi")
  let surfaceTitles: [String: String]
  /// surface ref -> workspace title (resolved through pane rows when present)
  let surfaceWorkspaces: [String: String]
  /// pid -> surface ref (resolved through process parent chains)
  let processSurfaces: [Int32: String]
  /// workspace ref -> workspace title (for single-workspace fallback)
  let workspaceTitles: [String: String]

  static func parse(_ tsv: String) -> CmuxSnapshot {
    struct Row {
      let kind: String
      let ref: String
      let parent: String
      let name: String
    }
    var rows: [Row] = []
    for line in tsv.split(separator: "\n") {
      let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard cols.count >= 7 else { continue }
      rows.append(Row(kind: cols[3], ref: cols[4], parent: cols[5], name: cols[6]))
    }

    // Ref graph for non-process rows (workspace/surface/pane/...).
    var refParent: [String: String] = [:]
    var surfaceTitles: [String: String] = [:]
    var workspaceTitles: [String: String] = [:]
    for row in rows where row.kind != "process" {
      refParent[row.ref] = row.parent
      if row.kind == "surface" { surfaceTitles[row.ref] = row.name }
      if row.kind == "workspace" { workspaceTitles[row.ref] = row.name }
    }

    // Walk surface -> pane -> workspace until a workspace ref is found.
    func workspaceTitle(forSurfaceRef ref: String) -> String? {
      var current = ref
      var seen: Set<String> = []
      while !seen.contains(current) {
        seen.insert(current)
        if let title = workspaceTitles[current] { return title }
        guard let parent = refParent[current], !parent.isEmpty else { return nil }
        current = parent
      }
      return nil
    }

    // Process rows: pid -> parent (a surface ref or another pid).
    var processParent: [Int32: String] = [:]
    for row in rows where row.kind == "process" {
      if let pid = Int32(row.ref) { processParent[pid] = row.parent }
    }

    // Walk pid -> parent pid -> ... until a surface ref is found.
    func surfaceRef(forPid pid: Int32) -> String? {
      var current = String(pid)
      var seen: Set<String> = []
      while !seen.contains(current) {
        seen.insert(current)
        if current.hasPrefix("surface:") { return current }
        guard let parentPid = Int32(current), let parent = processParent[parentPid] else { return nil }
        current = parent
      }
      return nil
    }

    var surfaceWorkspaces: [String: String] = [:]
    for ref in surfaceTitles.keys {
      if let title = workspaceTitle(forSurfaceRef: ref) { surfaceWorkspaces[ref] = title }
    }
    var processSurfaces: [Int32: String] = [:]
    for pid in processParent.keys {
      if let ref = surfaceRef(forPid: pid) { processSurfaces[pid] = ref }
    }

    return CmuxSnapshot(
      surfaceTitles: surfaceTitles,
      surfaceWorkspaces: surfaceWorkspaces,
      processSurfaces: processSurfaces,
      workspaceTitles: workspaceTitles
    )
  }

  /// Attribution for a pid chain (self first, then ancestors).
  /// Workspace falls back to the only known workspace when the pane link is missing.
  func attribution(chain: [Int32]) -> (workspace: String, surface: String)? {
    guard let hit = surfaceHit(chain: chain) else { return nil }
    return (hit.workspace, hit.surface)
  }

  /// Same lookup, plus the surface **ref** — needed to read that surface's
  /// scrollback (`cmux read-screen --surface <ref>`), which is how a
  /// cmux-launched process's own output becomes readable from outside cmux.
  func surfaceHit(chain: [Int32]) -> (workspace: String, surface: String, ref: String)? {
    for pid in chain {
      guard let ref = processSurfaces[pid], let title = surfaceTitles[ref] else { continue }
      let workspace = surfaceWorkspaces[ref]
        ?? (workspaceTitles.count == 1 ? workspaceTitles.values.first : nil)
      return (workspace ?? "?", title, ref)
    }
    return nil
  }
}
