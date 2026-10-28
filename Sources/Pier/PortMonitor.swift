import Combine
import Foundation

/// One probe's result, handed from its queue to the join point. The dispatch
/// group's leave/wait pair is the barrier that orders the write before the
/// read; `@unchecked Sendable` documents exactly that for the Swift 6 capture
/// check, which cannot see through `group.wait()`.
final class ProbeResult<T>: @unchecked Sendable {
  var value: T?
}

/// Polls lsof/ps/cmux on a background queue and publishes attributed port entries.
///
/// Main-actor: its state is `@Published` to SwiftUI and every mutation already
/// hopped to the main queue. The probes run off-main through `nonisolated`
/// statics that take and return values, never `self`.
@MainActor
final class PortMonitor: ObservableObject {
  @Published private(set) var entries: [PortEntry] = []
  @Published private(set) var activity: [ActivityEntry] = []
  /// Rolling CPU history keyed by pid, feeding the row sparklines.
  @Published private(set) var history = UsageHistory()
  /// Whether cmux workspace grouping is actually working, and why not.
  @Published private(set) var cmuxStatus: CmuxStatus = .notInstalled
  /// Whether Docker can be driven from here, and what a prune would reclaim.
  @Published private(set) var dockerState: EngineState = .cliMissing
  /// Same, for Apple's `container` engine.
  @Published private(set) var appleState: EngineState = .cliMissing
  /// Why the docker probe failed, when it did — populated only when the Docker
  /// CLI is present and the last probe produced a fault.
  @Published private(set) var dockerFault: DockerControl.Fault?
  @Published var dockerReclaimable: String?
  @Published var appleReclaimable: String?
  @Published private(set) var lastRefresh: Date?
  /// Heaviest CPU users by name, from the refresh's own `ps` table — the
  /// "who's making it hot" line in the CPU glance's tooltip.
  @Published private(set) var busiest: [BusyProcess] = []
  @Published private(set) var isRefreshing = false

  /// Fast polling while the menu bar window is open, slow in the background.
  /// Published so views that do work while open (the log drawer) can stop.
  @Published var windowVisible = false {
    didSet {
      // A fixture monitor promises "no timers, no probes" — `--probe-idle-cpu`
      // toggles this to reproduce a real open/close, and must not start
      // polling lsof underneath its own measurement.
      guard oldValue != windowVisible, !isFixture else { return }
      scheduleTimer()
      if windowVisible {
        refresh()
        refreshDockerDiskUsage()
        refreshAppleDiskUsage()
      }
    }
  }

  var tcpCount: Int { entries.filter { $0.proto == .tcp }.count }

  private var timer: Timer?
  /// Internal, not private: read by `commandLine(for:)` in +Actions.
  var commandCache: [Int32: String] = [:]
  /// The cmux socket password as of the last refresh. Cached so the log
  /// drawer's view doesn't re-read and re-parse `cmux.json` on every body
  /// evaluation — a file read on the main thread, several times a second
  /// while the drawer is open.
  var cmuxPassword: String?
  let cmuxPath: String?
  let dockerPath: String?
  let containerPath: String?

  /// The CLI a log source needs, or nil when it isn't installed.
  func toolPath(for source: LogSource) -> String? {
    switch source {
    case .docker: return dockerPath
    case .appleContainer: return containerPath
    case .cmuxSurface: return cmuxPath
    case .terminalTab: return "/usr/bin/osascript"
    case .unavailable: return nil
    }
  }

  init() {
    isFixture = false
    cmuxPath = PortMonitor.resolveCmux()
    dockerPath = PortMonitor.resolveBinary(
      "docker", candidates: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"])
    containerPath = PortMonitor.resolveBinary(
      "container", candidates: ["/usr/local/bin/container", "/opt/homebrew/bin/container"])
    scheduleTimer()
    refresh()
  }

  /// True when built from fixtures — lets views substitute static preview
  /// content instead of loading a live WKWebView during a fixture render.
  let isFixture: Bool

  /// Fixture/preview initializer: no timers, no probes.
  init(
    fixture entries: [PortEntry], activity: [ActivityEntry] = [],
    history: UsageHistory = UsageHistory(),
    dockerState: EngineState = .ready, appleState: EngineState = .ready,
    events: [PierEvent] = []
  ) {
    cmuxPath = nil
    dockerPath = nil
    containerPath = nil
    isFixture = true
    self.entries = entries
    self.activity = activity
    self.history = history
    // Fixtures pose as a healthy engine by default so the controls render in
    // PNGs; `--render-fixture-down` passes .unreachable to grade the other side.
    self.dockerState = dockerState
    self.appleState = appleState
    self.dockerReclaimable = "Images 3.1GB · Local Volumes 397.1MB"
    self.appleReclaimable = "Images 624.3 MB"
    self.lastRefresh = Date()
    self.events = events
  }

  private func scheduleTimer() {
    timer?.invalidate()
    let interval: TimeInterval = windowVisible ? 5 : 30
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      // Scheduled on RunLoop.main below, so this block always fires on main.
      MainActor.assumeIsolated { self?.refresh() }
    }
    timer.tolerance = interval * 0.2
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Newest first, capped — the panel's event feed and the badge count.
  /// Internal setter, not private(set): written by +Events.
  @Published var events: [PierEvent] = []
  /// Events since the panel was last opened. Drives the menu bar badge.
  @Published var unseenEvents = 0

  /// Previous refresh, for the differ. nil until the first one lands, which is
  /// what makes a cold start silent.
  /// Internal, not private: the differ lives in +Events.
  var lastSnapshot: MonitorSnapshot?
  /// Actions Pier itself just took, so the resulting event reads "you" rather
  /// than showing up as an unattributed kill ~5s later.
  var expectations: [(key: String, action: PierEvent.Action, expires: Date)] = []

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let cmuxPath = self.cmuxPath
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      // The four probes are independent, so they run concurrently and the
      // refresh takes as long as its slowest probe instead of their sum —
      // lsof alone can take ~500 ms, and the panel-open cadence is 5 s.
      // Each writes only its own box; the group joins them before any is
      // read, so the assembly below stays deterministic.
      let group = DispatchGroup()
      let socketsBox = ProbeResult<String>()
      let psBox = ProbeResult<String>()
      let fullPSBox = ProbeResult<String>()
      let cmuxBox = ProbeResult<(snapshot: CmuxSnapshot?, status: CmuxStatus)>()
      // Read once per refresh: it feeds the cmux probe's environment here and
      // the log drawer's copy below, instead of the view re-reading (and
      // re-parsing) the config file on every body evaluation.
      let cmuxPassword = CmuxAccess.socketPassword()

      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        // One lsof for both protocols: each call walks every process's file
        // table, so two calls cost twice as much for the same rows.
        socketsBox.value =
          ProcessRunner.run(
            "/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-iUDP"], timeout: 10)?
          .stdout ?? ""
        group.leave()
      }
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        // %cpu + rss ride along on the existing chain probe — no extra process.
        psBox.value =
          ProcessRunner.run(
            "/bin/ps", ["-axo", "pid=,ppid=,%cpu=,rss=,ucomm="], timeout: 5)?.stdout ?? ""
        group.leave()
      }
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        // Full command lines: shared by MCP detection and by path-based
        // harness attribution (a `node <path>/cli.js` harness is invisible
        // to ucomm).
        fullPSBox.value =
          ProcessRunner.run(
            "/bin/ps", ["-axo", "pid=,user=,command="], timeout: 5)?.stdout ?? ""
        group.leave()
      }
      // cmux is optional: tolerate absence/failure entirely — but record *why*
      // it didn't work, so a blocked socket can be reported instead of looking
      // like cmux isn't installed.
      if let cmuxPath {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
          var snapshot: CmuxSnapshot?
          let result = ProcessRunner.run(
            cmuxPath, CmuxAccess.arguments(), timeout: 3,
            environment: CmuxAccess.environment(password: cmuxPassword))
          let status = CmuxAccess.status(from: result) {
            snapshot = CmuxSnapshot.parse(result?.stdout ?? "")
            return snapshot?.workspaceTitles.count ?? 0
          }
          cmuxBox.value = (snapshot, status)
          group.leave()
        }
      }
      group.wait()
      let socketsOut = socketsBox.value ?? ""
      let psOut = psBox.value ?? ""
      let fullPS = fullPSBox.value ?? ""
      let cmux = cmuxBox.value?.snapshot
      let cmuxStatus = cmuxBox.value?.status ?? .notInstalled

      // Everything above this line talks to the world; everything below is a
      // pure function of what it returned, and is tested as one.
      let assembled = MonitorAssembly.ports(
        from: ProbeOutput(
          sockets: socketsOut, processTable: psOut, commandLines: fullPS, cmux: cmux,
          terminalInfo: { TerminalSessions.read(pid: $0) },
          projectInfo: { DevServers.readProject($0) }))
      // Stamp each row with its process's start time (libproc, ~1 µs per pid)
      // so a kill from a stale row can tell a recycled pid apart.
      var starts: [Int32: UInt64] = [:]
      // Hidden ports are dropped here, once, so the list, counts, search,
      // event feed and menu bar tooltip all agree they aren't there.
      let hidden = HiddenPorts.current()
      let entries = assembled.entries.filter { !hidden.contains($0.port) }.map {
        entry -> PortEntry in
        var entry = entry
        if starts[entry.pid] == nil { starts[entry.pid] = Self.startTime(of: entry.pid) }
        entry.startTime = starts[entry.pid]
        return entry
      }
      let table = assembled.table

      let activitySnapshot = Self.collectActivity(
        dockerPath: self?.dockerPath, containerPath: self?.containerPath,
        table: table, cmux: cmux, commandsOutput: fullPS, commands: assembled.commands)
      let activity = activitySnapshot.entries

      let readings = MonitorAssembly.cpuReadings(
        entries: entries, activity: activity, table: table)
      let busiest = table.busiest()

      DispatchQueue.main.async {
        guard let self else { return }
        self.entries = entries
        self.activity = activity
        self.cmuxPassword = cmuxPassword
        // Tooltips cache per pid; a machine that churns dev servers would
        // otherwise accumulate command lines for thousands of dead pids.
        self.commandCache = self.commandCache.filter { table.byPid[$0.key] != nil }
        if self.busiest != busiest { self.busiest = busiest }
        self.cmuxStatus = cmuxStatus
        // Only transitions are logged — a per-refresh line would bury the
        // interesting events under one entry every 5 seconds.
        if self.dockerState != activitySnapshot.dockerState {
          PierLog.shared.log("docker engine: \(self.dockerState) → \(activitySnapshot.dockerState)")
        }
        if self.appleState != activitySnapshot.appleState {
          PierLog.shared.log("apple engine: \(self.appleState) → \(activitySnapshot.appleState)")
        }
        self.dockerState = activitySnapshot.dockerState
        self.dockerFault = activitySnapshot.dockerFault
        self.appleState = activitySnapshot.appleState
        self.history.record(readings)
        let now = Date()
        self.recordEvents(ports: entries, activity: activity, now: now)
        self.lastRefresh = now
        self.isRefreshing = false
      }
    }
  }

  // MARK: - cmux discovery

  nonisolated static func resolveCmux() -> String? {
    resolveBinary(
      "cmux",
      candidates: [
        "/Applications/cmux.app/Contents/Resources/bin/cmux",
        "/opt/homebrew/bin/cmux",
        "/usr/local/bin/cmux",
      ])
  }

  /// Well-known install paths first, then `which` (menu-bar apps don't
  /// inherit a shell PATH).
  nonisolated static func resolveBinary(_ name: String, candidates: [String]) -> String? {
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
      return path
    }
    if let result = ProcessRunner.run("/usr/bin/which", [name], timeout: 2), result.exitCode == 0 {
      let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      if !path.isEmpty { return path }
    }
    return nil
  }
}
