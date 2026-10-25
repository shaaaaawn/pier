import Foundation

/// Everything one refresh read from the outside world, as plain values.
///
/// Splitting this out is what makes assembly testable. `refresh()` used to run
/// five `ProcessRunner` calls and then wire their results together inside the
/// same async closure — so the interesting decisions (which process owns a
/// port, whose harness spawned it, which cmux surface to read logs from) could
/// only be exercised by running the real binaries on a real machine.
struct ProbeOutput {
  /// `lsof +c 0 -nP -iTCP -sTCP:LISTEN -iUDP` — one call, both protocols.
  var sockets: String = ""
  /// `ps -axo pid=,ppid=,%cpu=,rss=,ucomm=`
  var processTable: String = ""
  /// `ps -axo pid=,user=,command=` — full command lines, needed for
  /// path-based harness attribution and MCP detection.
  var commandLines: String = ""
  /// nil when cmux isn't installed or refused the socket.
  var cmux: CmuxSnapshot?
}

/// The assembled result, plus the intermediate tables the caller still needs.
struct AssembledPorts {
  var entries: [PortEntry]
  var table: ProcessTable
  var commands: [Int32: String]
}

/// Pure assembly: raw command output in, finished rows out. No processes, no
/// clock, no globals — the same contract the individual parsers already keep,
/// applied one level up.
enum MonitorAssembly {
  static func ports(from probe: ProbeOutput) -> AssembledPorts {
    var entries = PortMonitor.buildEntries(sockets: probe.sockets)
    let table = ProcessTable.parse(probe.processTable)
    let commands = PortMonitor.parseCommands(probe.commandLines)

    // One cache per refresh, shared by every entry: their ancestor chains
    // overlap heavily. Built here and dropped with this call, so a reused pid
    // can never inherit a stale label.
    let labels = CommandLabelCache(commands)
    for i in entries.indices {
      entries[i].attribution = Attributor.attribute(
        entry: entries[i], table: table, cmux: probe.cmux, labels: labels)
      entries[i].usage = table.usage(for: entries[i].pid)
      // Kept alongside the label so the log panel can read that surface's
      // scrollback — the only way a dev server's own output is readable from
      // outside the terminal running it.
      entries[i].cmuxSurfaceRef =
        probe.cmux?.surfaceHit(chain: table.chain(from: entries[i].pid).map(\.pid))?.ref
    }
    return AssembledPorts(entries: entries, table: table, commands: commands)
  }

  /// One CPU sample per pid Pier is showing, so every row's sparkline has a
  /// series. Ports and activity rows both contribute; a pid in both is read
  /// once from the same table, so the two can't disagree.
  static func cpuReadings(
    entries: [PortEntry], activity: [ActivityEntry], table: ProcessTable
  ) -> [Int32: Double] {
    var readings: [Int32: Double] = [:]
    for entry in entries {
      readings[entry.pid] = table.byPid[entry.pid]?.cpu ?? 0
    }
    for item in activity {
      // A simulator's pid is its launchd_sim, which idles near zero; the row
      // reports the whole device, so its sparkline has to plot that too.
      if item.kind == .simulator, let pid = item.pids.first, let usage = item.usage {
        readings[pid] = usage.cpu
        continue
      }
      for pid in item.pids { readings[pid] = table.byPid[pid]?.cpu ?? 0 }
    }
    return readings
  }
}
