import Combine
import Foundation

/// Polls lsof/ps/cmux on a background queue and publishes attributed port entries.
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
  /// Why the docker probe failed, when it did — populated only while
  /// `dockerState` is not ready.
  @Published private(set) var dockerFault: DockerControl.Fault?
  @Published private(set) var dockerReclaimable: String?
  @Published private(set) var appleReclaimable: String?
  @Published private(set) var lastRefresh: Date?
  @Published private(set) var isRefreshing = false

  /// Fast polling while the menu bar window is open, slow in the background.
  var windowVisible = false {
    didSet {
      guard oldValue != windowVisible else { return }
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
  private var commandCache: [Int32: String] = [:]
  let cmuxPath: String?
  let dockerPath: String?
  let containerPath: String?

  /// The CLI a log source needs, or nil when it isn't installed.
  func toolPath(for source: LogSource) -> String? {
    switch source {
    case .docker: return dockerPath
    case .appleContainer: return containerPath
    case .cmuxSurface: return cmuxPath
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
      self?.refresh()
    }
    timer.tolerance = interval * 0.2
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Newest first, capped — the panel's event feed and the badge count.
  @Published private(set) var events: [PierEvent] = []
  /// Events since the panel was last opened. Drives the menu bar badge.
  @Published private(set) var unseenEvents = 0

  /// Previous refresh, for the differ. nil until the first one lands, which is
  /// what makes a cold start silent.
  private var lastSnapshot: MonitorSnapshot?
  /// Actions Pier itself just took, so the resulting event reads "you" rather
  /// than showing up as an unattributed kill ~5s later.
  private var expectations: [(key: String, action: PierEvent.Action, expires: Date)] = []

  static let maxEvents = 200

  /// Record that Pier is about to cause an event, so the differ can label it.
  /// 60s of slack: `docker stop` can take a while, and a 30s poll may miss the
  /// window entirely when the panel is closed.
  func expect(_ action: PierEvent.Action, subject: PierEvent.Subject, ttl: TimeInterval = 60) {
    expectations.append((key: subject.key, action: action, expires: Date().addingTimeInterval(ttl)))
  }

  func markEventsSeen() {
    unseenEvents = 0
  }

  /// Diff this refresh against the last and record what changed.
  private func recordEvents(ports: [PortEntry], activity: [ActivityEntry], now: Date) {
    let snapshot = MonitorSnapshot(ports: ports, activity: activity)
    defer { lastSnapshot = snapshot }
    guard !isFixture else { return }
    expectations.removeAll { $0.expires < now }
    var fresh = EventDiff.between(old: lastSnapshot, new: snapshot, at: now)
    guard !fresh.isEmpty else { return }
    for i in fresh.indices {
      if let match = expectations.firstIndex(where: {
        $0.key == fresh[i].subject.key && $0.action == fresh[i].action
      }) {
        fresh[i].selfInitiated = true
        expectations.remove(at: match)
      }
      PierLog.shared.log("event: \(fresh[i].summary)")
    }
    events = (fresh.reversed() + events).prefix(Self.maxEvents).map { $0 }
    unseenEvents += fresh.filter { !$0.selfInitiated }.count
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let cmuxPath = self.cmuxPath
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let tcpOut =
        ProcessRunner.run(
          "/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN"], timeout: 10)?.stdout ?? ""
      let udpOut =
        ProcessRunner.run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iUDP"], timeout: 10)?.stdout ?? ""
      // %cpu + rss ride along on the existing chain probe — no extra process.
      let psOut =
        ProcessRunner.run(
          "/bin/ps", ["-axo", "pid=,ppid=,%cpu=,rss=,ucomm="], timeout: 5)?.stdout ?? ""

      // cmux is optional: tolerate absence/failure entirely — but record *why*
      // it didn't work, so a blocked socket can be reported instead of looking
      // like cmux isn't installed.
      var cmux: CmuxSnapshot?
      var cmuxStatus: CmuxStatus = .notInstalled
      if let cmuxPath {
        let result = ProcessRunner.run(
          cmuxPath, CmuxAccess.arguments(), timeout: 3,
          environment: CmuxAccess.environment(password: CmuxAccess.socketPassword()))
        cmuxStatus = CmuxAccess.status(from: result) {
          let snapshot = CmuxSnapshot.parse(result?.stdout ?? "")
          cmux = snapshot
          return snapshot.workspaceTitles.count
        }
      }

      var entries = Self.buildEntries(tcp: tcpOut, udp: udpOut)
      let table = ProcessTable.parse(psOut)
      // Full command lines: shared by MCP detection and by path-based harness
      // attribution (a `node <path>/cli.js` harness is invisible to ucomm).
      let fullPS =
        ProcessRunner.run(
          "/bin/ps", ["-axo", "pid=,user=,command="], timeout: 5)?.stdout ?? ""
      let commands = Self.parseCommands(fullPS)
      for i in entries.indices {
        entries[i].attribution = Attributor.attribute(
          entry: entries[i], table: table, cmux: cmux, commands: commands)
        entries[i].usage = table.usage(for: entries[i].pid)
        // Keep the surface ref alongside the label so the log panel can read
        // that surface's scrollback.
        entries[i].cmuxSurfaceRef =
          cmux?
          .surfaceHit(chain: table.chain(from: entries[i].pid).map(\.pid))?.ref
      }

      let activity = Self.collectActivity(
        dockerPath: self?.dockerPath, containerPath: self?.containerPath,
        table: table, cmux: cmux, commandsOutput: fullPS)

      // CPU readings for everything we list, so the sparklines have a series.
      var readings: [Int32: Double] = [:]
      for entry in entries {
        readings[entry.pid] = table.byPid[entry.pid]?.cpu ?? 0
      }
      for item in activity {
        for pid in item.pids { readings[pid] = table.byPid[pid]?.cpu ?? 0 }
      }

      DispatchQueue.main.async {
        guard let self else { return }
        self.entries = entries
        self.activity = activity
        self.cmuxStatus = cmuxStatus
        // Only transitions are logged — a per-refresh line would bury the
        // interesting events under one entry every 5 seconds.
        if self.dockerState != Self.lastDockerState {
          PierLog.shared.log("docker engine: \(self.dockerState) → \(Self.lastDockerState)")
        }
        if self.appleState != Self.lastAppleState {
          PierLog.shared.log("apple engine: \(self.appleState) → \(Self.lastAppleState)")
        }
        self.dockerState = Self.lastDockerState
        self.dockerFault = Self.lastDockerFault
        self.appleState = Self.lastAppleState
        self.history.record(readings)
        let now = Date()
        self.recordEvents(ports: entries, activity: activity, now: now)
        self.lastRefresh = now
        self.isRefreshing = false
      }
    }
  }

  /// Merge lsof records into entries, deduped by pid+port+protocol with
  /// distinct bind addresses collected.
  static func buildEntries(tcp: String, udp: String) -> [PortEntry] {
    var order: [String] = []
    var byKey: [String: PortEntry] = [:]
    let records = LsofParser.parse(tcp, proto: .tcp) + LsofParser.parse(udp, proto: .udp)
    for record in records {
      let key = "\(record.pid):\(record.port):\(record.proto.rawValue)"
      if var entry = byKey[key] {
        if !entry.bindAddresses.contains(record.bindAddress) {
          entry.bindAddresses.append(record.bindAddress)
          byKey[key] = entry
        }
      } else {
        byKey[key] = PortEntry(
          pid: record.pid, port: record.port, proto: record.proto,
          processName: record.command, user: record.user,
          bindAddresses: [record.bindAddress], attribution: .none
        )
        order.append(key)
      }
    }
    return order.compactMap { byKey[$0] }
  }

  /// Apply the scope chip + hide-system toggle before grouping. Pure so the
  /// chip semantics are unit-testable rather than buried in the view.
  static func visibleEntries(
    _ entries: [PortEntry], filter: PierFilter, hideSystem: Bool
  ) -> [PortEntry] {
    guard filter.showsPorts else { return [] }
    return entries.filter { entry in
      guard filter.admits(entry) else { return false }
      if hideSystem, entry.attribution == .system { return false }
      return true
    }
  }

  /// Filtered, grouped (attributed first, Other, then System), clustered by
  /// pid+attribution, ordered by `sort`. Pure/static for testability.
  static func buildGroups(
    entries: [PortEntry], matching query: String, sort: PortSort = .port,
    history: UsageHistory = UsageHistory()
  ) -> [PortGroup] {
    var groupOrder: [String] = []
    var rankByTitle: [String: Int] = [:]
    var bucketsByTitle: [String: [String: [PortEntry]]] = [:]
    var bucketOrderByTitle: [String: [String]] = [:]

    for entry in entries {
      let title = entry.attribution.groupTitle
      if bucketsByTitle[title] == nil {
        groupOrder.append(title)
        bucketsByTitle[title] = [:]
        bucketOrderByTitle[title] = []
      }
      rankByTitle[title] = entry.attribution.groupRank
      let key = "\(entry.pid)|\(entry.attribution.badgeLabel)"
      if bucketsByTitle[title]![key] == nil {
        bucketOrderByTitle[title]!.append(key)
        bucketsByTitle[title]![key] = []
      }
      bucketsByTitle[title]![key]!.append(entry)
    }

    return
      groupOrder
      .map { title -> PortGroup in
        let rows: [PortRow] = bucketOrderByTitle[title]!.compactMap { key in
          let bucket = bucketsByTitle[title]![key]!
            .sorted { ActivityRank.areInOrder($0, $1, sort: sort, history: history) }
          let visible = query.isEmpty ? bucket : bucket.filter { $0.matches(query) }
          guard !visible.isEmpty else { return nil }
          return PortRow(
            entries: visible,
            totalCount: bucket.count,
            autoExpanded: !query.isEmpty && visible.count < bucket.count
          )
        }
        .sorted { ActivityRank.areInOrder($0.primary, $1.primary, sort: sort, history: history) }
        return PortGroup(title: title, rank: rankByTitle[title] ?? 1, rows: rows)
      }
      .filter { !$0.rows.isEmpty }
      .sorted { a, b in
        // Activity mode floats the section holding the most interesting
        // listener; otherwise the semantic order (agents, Other, System) holds.
        // System stays pinned last either way — it's never the answer to "what
        // am I running?", however busy it gets.
        if sort == .activity, a.rank != Attribution.system.groupRank,
          b.rank != Attribution.system.groupRank
        {
          let left =
            a.rows.map {
              ActivityRank.score($0.primary, series: history.series(for: $0.primary.pid))
            }.max() ?? 0
          let right =
            b.rows.map {
              ActivityRank.score($0.primary, series: history.series(for: $0.primary.pid))
            }.max() ?? 0
          if left != right { return left > right }
        }
        return (a.rank, a.title) < (b.rank, b.title)
      }
  }

  func groups(matching query: String) -> [PortGroup] {
    Self.buildGroups(entries: entries, matching: query)
  }

  func groups(
    matching query: String, filter: PierFilter, hideSystem: Bool, sort: PortSort = .activity
  ) -> [PortGroup] {
    Self.buildGroups(
      entries: Self.visibleEntries(entries, filter: filter, hideSystem: hideSystem),
      matching: query, sort: sort, history: history)
  }

  /// Count shown in the header: what the current scope/search actually lists.
  func visibleCount(matching query: String, filter: PierFilter, hideSystem: Bool) -> Int {
    groups(matching: query, filter: filter, hideSystem: hideSystem)
      .reduce(0) { $0 + $1.entryCount }
      + activityGroups(matching: query, filter: filter).reduce(0) { $0 + $1.entryCount }
  }

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
  /// Set by `collectActivity` so the caller can publish it (the collector is
  /// static so it stays callable from the CLI probes).
  /// Why the last docker probe failed, when it did. Kept beside the state so
  /// the panel can say "not responding — <reason>" instead of the misleading
  /// "not running" for an engine that is running but refusing.
  nonisolated(unsafe) static var lastDockerFault: DockerControl.Fault?
  nonisolated(unsafe) static var lastDockerState: EngineState = .cliMissing
  nonisolated(unsafe) static var lastAppleState: EngineState = .cliMissing

  static func collectActivity(
    dockerPath: String?, containerPath: String?, table: ProcessTable, cmux: CmuxSnapshot?,
    commandsOutput: String? = nil
  ) -> [ActivityEntry] {
    var activity: [ActivityEntry] = []
    var dockerState = EngineState.cliMissing
    if let dockerPath {
      let result = ProcessRunner.run(
        dockerPath,
        ["ps", "-a", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"],
        timeout: 5)
      dockerState = DockerControl.state(from: result, cliInstalled: true)
      lastDockerFault = DockerControl.fault(from: result, cliInstalled: true)
      if dockerState.isReady, let result {
        activity += ActivityParser.parseDockerPS(result.stdout)
      }
    } else {
      lastDockerFault = nil
    }
    lastDockerState = dockerState
    var appleState = EngineState.cliMissing
    if let containerPath {
      let result = ProcessRunner.run(containerPath, ["list", "--all"], timeout: 8)
      appleState = AppleControl.state(from: result, cliInstalled: true)
      if appleState.isReady, let result {
        activity += ActivityParser.parseContainerList(result.stdout)
      }
    }
    lastAppleState = appleState
    let fullPS =
      commandsOutput
      ?? ProcessRunner.run("/bin/ps", ["-axo", "pid=,user=,command="], timeout: 5)?.stdout ?? ""
    activity += ActivityParser.mcpEntries(fullPS: fullPS, table: table, cmux: cmux)
    return activity
  }

  /// `Pier --print-activity`: one synchronous collection pass, printed as
  /// text. Lets the detectors be verified live without opening the panel.
  static func printActivitySnapshot() {
    let psOut =
      ProcessRunner.run("/bin/ps", ["-axo", "pid=,ppid=,ucomm="], timeout: 5)?.stdout ?? ""
    let activity = collectActivity(
      dockerPath: resolveBinary(
        "docker", candidates: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]),
      containerPath: resolveBinary(
        "container", candidates: ["/usr/local/bin/container", "/opt/homebrew/bin/container"]),
      table: ProcessTable.parse(psOut),
      cmux: nil)
    for kind in [ActivityKind.docker, .apple, .mcp] {
      let entries = activity.filter { $0.kind == kind }
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

  // MARK: - cmux discovery

  static func resolveCmux() -> String? {
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
  static func resolveBinary(_ name: String, candidates: [String]) -> String? {
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
