import AppKit
import UserNotifications

/// Command-line entry points used for design iteration and verification.
/// Each one runs before the app loop and exits, so none of them touch the
/// live menu bar. `--probe-anchor` is the exception: it needs the real status
/// item, so it's handled in AppDelegate after launch.
///
/// Main-actor: `main.swift` calls in from top-level code, before the run loop,
/// and the probes drive the same main-actor objects the app does.
@MainActor
enum DebugFlags {
  static func handleIfPresent(_ args: [String]) {
    if args.contains("--print-memory") {
      MemoryProbe.printMemory()
      exit(0)
    }
    if let dir = value(after: "--render-fixture-statusitem", in: args) {
      MainActor.assumeIsolated { StatusItemFixture.render(to: dir) }
    }
    if let dir = value(after: "--render-fixture-dev", in: args) {
      MainActor.assumeIsolated { DevFixture.render(to: dir) }
    }
    if let dir = value(after: "--render-fixture-terminals", in: args) {
      MainActor.assumeIsolated { TerminalFixture.render(to: dir) }
    }
    if let dir = value(after: "--render-fixture-simulators", in: args) {
      MainActor.assumeIsolated { SimulatorFixture.render(to: dir) }
    }
    if let dir = value(after: "--render-fixture-memory", in: args) {
      MainActor.assumeIsolated { MemoryProbe.renderFixtures(to: dir) }
    }
    if args.contains("--probe-statusitem") {
      MainActor.assumeIsolated { probeStatusItem() }
      exit(0)
    }
    if args.contains("--probe-self-event") {
      probeSelfEvent()
    }
    if args.contains("--probe-notify") {
      probeNotify()
    }
    if args.contains("--log-path") {
      print(PierLog.fileURL.path)
      exit(0)
    }
    if args.contains("--tail-log") {
      let count = value(after: "--tail-log", in: args).flatMap(Int.init) ?? 50
      let text = PierLog.tail(count)
      print(text.isEmpty ? "(no log yet at \(PierLog.fileURL.path))" : text)
      exit(0)
    }
    if args.contains("--print-activity") {
      PortMonitor.printActivitySnapshot()
      exit(0)
    }
    if let name = value(after: "--tail-docker", in: args) {
      tailDocker(container: name)
    }
    if args.contains("--print-groups") {
      printGroups()
      exit(0)
    }
    if args.contains("--print-apple") {
      printAppleState()
      exit(0)
    }
    if args.contains("--print-docker") {
      printDockerState()
      exit(0)
    }
    if args.contains("--watch-menubar") {
      watchMenuBar()
      exit(0)
    }
    if args.contains("--print-menubar") {
      printMenuBarState()
      exit(0)
    }
    if args.contains("--print-cmux") {
      printCmuxStatus()
      exit(0)
    }
    if let path = value(after: "--render-fixture-preview", in: args) {
      MainActor.assumeIsolated { FixtureRenderer.renderPreview(to: path) }
    }
    if let path = value(after: "--render-fixture-narrow", in: args) {
      MainActor.assumeIsolated { FixtureRenderer.renderNarrow(to: path) }
    }
    if let path = value(after: "--render-fixture-events", in: args) {
      MainActor.assumeIsolated { FixtureRenderer.renderEvents(to: path) }
    }
    if let path = value(after: "--render-fixture-down", in: args) {
      MainActor.assumeIsolated { FixtureRenderer.renderEnginesDown(to: path) }
    }
    if let path = value(after: "--render-fixture-idle", in: args) {
      MainActor.assumeIsolated { FixtureRenderer.renderIdleEngines(to: path) }
    }
    if let path = value(after: "--render-fixture-logs", in: args) {
      MainActor.assumeIsolated { FixtureRenderer.renderLogs(to: path) }
    }
    if let path = value(after: "--render-fixture-expanded", in: args) {
      MainActor.assumeIsolated { FixtureRenderer.renderExpanded(to: path) }
    }
    if let path = value(after: "--render-fixture-activity", in: args) {
      MainActor.assumeIsolated { FixtureRenderer.renderActivity(to: path) }
    }
    if let index = args.firstIndex(of: "--render-fixture"), args.count > index + 1 {
      MainActor.assumeIsolated {
        FixtureRenderer.render(
          to: args[index + 1], scope: args.count > index + 2 ? args[index + 2] : nil)
      }
    }
    if let index = args.firstIndex(of: "--probe-click"), args.count > index + 2,
      let port = Int(args[index + 1])
    {
      MainActor.assumeIsolated { ClickProbe.run(port: port, dir: args[index + 2]) }
    }
    if let index = args.firstIndex(of: "--probe-preview"), args.count > index + 2,
      let port = Int(args[index + 1])
    {
      MainActor.assumeIsolated { PreviewProbe.run(port: port, out: args[index + 2]) }
    }
    if let index = args.firstIndex(of: "--probe-idle-cpu") {
      let seconds = args.count > index + 1 ? Int(args[index + 1]) ?? 8 : 8
      MainActor.assumeIsolated { FixtureRenderer.probeIdleCPU(seconds: seconds) }
    }
    if let index = args.firstIndex(of: "--probe-viewport"), args.count > index + 1 {
      MainActor.assumeIsolated {
        FixtureRenderer.probeViewport(
          url: args[index + 1], out: args.count > index + 2 ? args[index + 2] : nil)
      }
    }
  }

  /// `--print-apple`: Apple container engine state and reclaimable space.
  /// Read-only — it never prunes and never starts the service.
  private static func printAppleState() {
    let cli = PortMonitor.resolveBinary(
      "container", candidates: ["/usr/local/bin/container", "/opt/homebrew/bin/container"])
    print("container CLI: \(cli ?? "not installed")")
    guard let cli else { return }
    let list = ProcessRunner.run(cli, ["list"], timeout: 10)
    let state = AppleControl.state(from: list, cliInstalled: true)
    print("engine:        \(state)")
    print("  (list exit code was \(list?.exitCode ?? -1) — text is what decides)")
    guard state.isReady else {
      print("  start with: container \(AppleAction.start.arguments.joined(separator: " "))")
      return
    }
    let rows = (list?.stdout ?? "").split(separator: "\n").dropFirst()
    print("containers:    \(rows.isEmpty ? "none" : "\(rows.count)")")
    if let df = ProcessRunner.run(cli, ["system", "df"], timeout: 15), df.exitCode == 0 {
      for row in AppleControl.parseDiskUsage(df.stdout) {
        print("  \(row.kind): size \(row.size), reclaimable \(row.reclaimable)")
      }
      print(
        "summary:       \(AppleControl.reclaimableSummary(AppleControl.parseDiskUsage(df.stdout)) ?? "nothing to reclaim")"
      )
    }
  }

  /// `--print-groups`: the section titles and row counts the panel would show.
  /// Verifies attribution end-to-end, including cmux workspace grouping.
  private static func printGroups() {
    let monitor = PortMonitor()
    print("cmux CLI: \(monitor.cmuxPath ?? "not found")")
    // A full cycle runs lsof, ps twice, cmux and docker — allow for it.
    let deadline = Date().addingTimeInterval(45)
    while monitor.lastRefresh == nil, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    guard monitor.lastRefresh != nil else {
      print("refresh did not complete within 45s")
      return
    }
    print("ports seen: \(monitor.entries.count)")
    let groups = monitor.groups(matching: "", filter: .all, hideSystem: false)
    print("port groups (\(groups.count)):")
    for group in groups {
      print("  \(group.title) — \(group.entryCount) port(s)")
      for row in group.rows.prefix(3) {
        let extra = row.primary.attribution.rowBadge(inGroup: group.title)
        print(
          "      \(row.primary.port) \(row.primary.processName)\(extra.map { " · " + $0 } ?? "")")
      }
    }
    // The Dev scope: what the classifier calls a dev server, by project.
    let dev = monitor.groups(matching: "", filter: .dev, hideSystem: false)
    print("dev servers (\(dev.reduce(0) { $0 + $1.entryCount })):")
    for group in dev {
      print("  \(group.title)")
      for row in group.rows {
        let e = row.primary
        print(
          "      \(e.port) \(e.dev?.framework ?? "?") — \(e.processName) · \(e.attribution.badgeLabel)"
        )
      }
    }
    print("cmux: \(monitor.cmuxStatus)")
  }

  /// `--watch-menubar`: sample the signals that could tell us the bar hid, for
  /// 12s, printing only changes. Shows which signal changes when the bar
  /// auto-hides; the panel uses it when choosing its initial anchor.
  private static func watchMenuBar() {
    print("sampling 12s — hover the menu bar, then move away…")
    var last = ""
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      let visible = NSMenu.menuBarVisible()
      let thickness = NSStatusBar.system.thickness
      let reserved = NSScreen.screens.map { screen -> String in
        let r = screen.frame.maxY - screen.visibleFrame.maxY
        return "\(Int(screen.frame.width))w:\(Int(r))pt"
      }.joined(separator: " ")
      // The signal that actually moves: which displays currently draw a bar.
      let drawn = NSScreen.screens.map { screen in
        MenuBarVisibility.isBarVisible(on: screen) ? "1" : "0"
      }.joined()
      let sample =
        "barDrawn[\(drawn)] bars=\(MenuBarVisibility.barRects().count) "
        + "· (static: menuBarVisible=\(visible) thickness=\(Int(thickness)) reserved[\(reserved)])"
      if sample != last {
        print("  \(String(format: "%.1f", 12 - deadline.timeIntervalSinceNow * -1))s  \(sample)")
        last = sample
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    print("done. barDrawn[] is per display, in NSScreen.screens order — that is the")
    print("signal Pier observes. The parenthesised ones never move; they are")
    print("printed only to show that they don't.")
  }

  /// `--print-menubar`: whether the menu bar currently reserves space on each
  /// display, and where a panel would initially be anchored as a result. Run it
  /// from a normal desktop and again from a fullscreen space to compare states.
  private static func printMenuBarState() {
    for screen in NSScreen.screens {
      let reserved = screen.frame.maxY - screen.visibleFrame.maxY
      let state =
        reserved > 1
        ? "\(Int(reserved))pt reserved"
        : "NOT reserved (fullscreen / auto-hide)"
      let drawn = MenuBarVisibility.isBarVisible(on: screen)
      print(
        "screen \(Int(screen.frame.width))×\(Int(screen.frame.height)) at y\(Int(screen.frame.minY)): \(state)"
      )
      print("   bar drawn right now: \(drawn)")
      // Where a panel would hang, for an item at this screen's top-right.
      let button = NSRect(
        x: screen.frame.maxX - 200, y: screen.frame.maxY - 22, width: 57, height: 22)
      let frame = PanelPlacement.frame(
        buttonRect: button, visibleFrame: screen.visibleFrame,
        size: NSSize(width: 440, height: 560), barVisible: drawn)
      print(
        "   a panel would top out at y\(Int(frame.maxY)) (screen top is y\(Int(screen.frame.maxY)))"
      )
    }
    print("\nbar rects seen on screen: \(MenuBarVisibility.barRects().count)")
    for bar in MenuBarVisibility.barRects() {
      print("   x\(Int(bar.minX)) y\(Int(bar.minY)) \(Int(bar.width))×\(Int(bar.height))")
    }
    print("\nmacOS only holds the bar down for a tracking NSMenu. Pier anchors")
    print("once when the panel opens, then keeps it still as the bar changes.")
  }

  /// `--print-docker`: engine state and what a prune would reclaim. Read-only —
  /// it never runs a prune.
  private static func printDockerState() {
    let docker = PortMonitor.resolveBinary(
      "docker", candidates: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"])
    print("docker CLI: \(docker ?? "not installed")")
    guard let docker else { return }
    let ps = ProcessRunner.run(docker, ["ps", "--format", "{{.Names}}"], timeout: 8)
    let state = DockerControl.state(from: ps, cliInstalled: true)
    print("engine:     \(state)")
    if let fault = DockerControl.fault(from: ps, cliInstalled: true) {
      print("fault:      \(fault.headline)")
      if let detail = fault.detail { print("because:    \(detail)") }
    }
    // `docker desktop status` is shown only to make the discrepancy visible —
    // it is deliberately NOT what `state` is based on.
    if let status = ProcessRunner.run(docker, ["desktop", "status"], timeout: 8)?.stdout {
      let line = status.split(separator: "\n").first { $0.contains("Status") }
      print("desktop status says: \(line?.trimmingCharacters(in: .whitespaces) ?? "?")")
    }
    guard state.isReady else { return }
    let containers = (ps?.stdout ?? "").split(separator: "\n")
    print("containers: \(containers.isEmpty ? "none running" : containers.joined(separator: ", "))")
    if let df = ProcessRunner.run(docker, ["system", "df"], timeout: 12), df.exitCode == 0 {
      let rows = DockerControl.parseDiskUsage(df.stdout)
      for row in rows { print("  \(row.kind): size \(row.size), reclaimable \(row.reclaimable)") }
      print("summary:    \(DockerControl.reclaimableSummary(rows) ?? "nothing to reclaim")")
    }
  }

  /// `--tail-docker <container>`: exercise the real streaming tailer against a
  /// live container. Fixture renders substitute static lines, so this is the
  /// only check that `docker logs --follow` actually streams into the panel.
  private static func tailDocker(container: String) -> Never {
    let source = LogSource.docker(container: container)
    let docker = PortMonitor.resolveBinary(
      "docker", candidates: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"])
    print("source: \(source.label)")
    print("tool:   \(docker ?? "docker not found")")
    MainActor.assumeIsolated {
      let tailer = LogTailer()
      tailer.start(source: source, toolPath: docker)
      // Give the stream a moment, then report what arrived.
      DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
        print("state:  \(tailer.state)")
        print("lines:  \(tailer.lines.count)")
        for line in tailer.lines.suffix(6) { print("   | \(line)") }
        tailer.stop()
        exit(tailer.lines.isEmpty ? 1 : 0)
      }
    }
    NSApplication.shared.run()
    exit(0)
  }

  /// `--print-cmux`: whether workspace grouping can work, and why not. Runs the
  /// real code path against the real config, so it also confirms Pier picks up a
  /// socketPassword.
  private static func printCmuxStatus() {
    let path = PortMonitor.resolveCmux()
    print("cmux CLI: \(path ?? "not found")")
    print("config:   \(CmuxAccess.configPath)")
    if let text = try? String(contentsOfFile: CmuxAccess.configPath, encoding: .utf8) {
      let parsed = CmuxAccess.parseConfig(text)
      let password = parsed.password ?? ""
      print("  socketControlMode: \(parsed.mode ?? "(unset)")")
      print(
        "  socketPassword:    \(password.isEmpty ? "(empty)" : "set, \(password.count) chars")")
    } else {
      print("  (config unreadable)")
    }
    guard let path else { return }
    let result = ProcessRunner.run(
      path, CmuxAccess.arguments(), timeout: 5,
      environment: CmuxAccess.environment(password: CmuxAccess.socketPassword()))
    var workspaces = 0
    let status = CmuxAccess.status(from: result) {
      let snapshot = CmuxSnapshot.parse(result?.stdout ?? "")
      workspaces = snapshot.workspaceTitles.count
      return workspaces
    }
    print("status:   \(status)")
    if case .connected = status {
      let snapshot = CmuxSnapshot.parse(result?.stdout ?? "")
      print("  workspaces: \(snapshot.workspaceTitles.values.sorted().joined(separator: ", "))")
      print("  surfaces:   \(snapshot.surfaceTitles.count)")
      print("  processes mapped: \(snapshot.processSurfaces.count)")
    } else if let detail = status.detail {
      print("\n\(detail)")
    }
  }

  /// `--probe-statusitem`: the four ways a menu bar icon goes missing. Prints
  /// the persisted defaults that can hide or misplace it, what a freshly
  /// created item reports about itself, and whether the system has taken it
  /// away. Read-only — it never writes defaults.
  @MainActor
  private static func probeStatusItem() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let defaults = UserDefaults.standard
    let name = StatusItemRepair.autosaveName
    print("autosave name: \(name)")

    let keys = defaults.dictionaryRepresentation().keys
      .filter { $0.hasPrefix("NSStatusItem ") }
      .sorted()
    if keys.isEmpty {
      print("persisted keys: none")
    } else {
      for key in keys {
        let value = defaults.object(forKey: key) ?? "nil"
        var note = ""
        if key.hasPrefix(StatusItemRepair.positionPrefix) {
          let maxX = NSScreen.screens.map { Double($0.frame.maxX) }.max()
          note =
            StatusItemRepair.shouldClearPosition(value, maxScreenX: maxX)
            ? "  ← WOULD CLEAR (off-screen)" : ""
        } else if key.hasPrefix(StatusItemRepair.visibilityPrefix) {
          note =
            StatusItemRepair.shouldClearVisibility(
              key: key, value: value, autosaveName: name) ? "  ← WOULD CLEAR (stale hidden)" : ""
        }
        print("  \(key) = \(value)\(note)")
      }
    }
    print("widest screen maxX: \(NSScreen.screens.map { $0.frame.maxX }.max() ?? 0)")

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "?"
    let snapshot = StatusItemRepair.snapshot(item)
    print("fresh item:    \(snapshot)")
    print("system-hidden: \(StatusItemRepair.isSystemHidden(snapshot))")
    NSStatusBar.system.removeStatusItem(item)
  }

  /// `--probe-self-event`: does an action *Pier* took get labeled "you" instead
  /// of showing up as an unattributed kill? Unit tests can't reach this — the
  /// tag is set when a real refresh diff matches an expectation recorded by the
  /// button handler. Spawns its own throwaway listener, kills it through the
  /// same `terminate(_:)` the Kill button calls, and prints the resulting event.
  /// Touches nothing else on the machine.
  private static func probeSelfEvent() -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let port = 8971
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-m", "http.server", "\(port)"]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    do { try server.run() } catch {
      print("could not start test listener: \(error.localizedDescription)")
      exit(1)
    }
    print("spawned test listener on :\(port) (pid \(server.processIdentifier))")

    let monitor = PortMonitor()
    // Panel-open cadence, so the probe finishes in seconds not minutes.
    monitor.windowVisible = true
    var killed = false

    func poll() {
      let entry = monitor.entries.first { $0.port == port }
      if !killed, let entry {
        print("seen as: \(entry.processName) (pid \(entry.pid))")
        killed = true
        monitor.terminate(entry.pid)  // the exact call the Kill button makes
        print("called terminate() — waiting for the diff")
      }
      if killed,
        let event = monitor.events.first(where: {
          if case .port(let p, _) = $0.subject { return p == port && $0.action == .stopped }
          return false
        })
      {
        print("event:   \(event.summary)")
        print("self:    \(event.selfInitiated)")
        print(event.selfInitiated ? "PASS — reads as you" : "FAIL — looks unattributed")
        exit(event.selfInitiated ? 0 : 1)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
      server.terminate()
      print("TIMEOUT — no stop event in 60s")
      exit(3)
    }
    NSApp.run()
    exit(0)
  }

  /// `--probe-notify`: can this ad-hoc signed LSUIElement bundle actually post
  /// a local notification? Must run from `dist/Pier.app/Contents/MacOS/Pier` —
  /// `UNUserNotificationCenter` needs a real bundle, and the bare SPM binary
  /// has none. Prints the authorization status and any delivery error.
  private static func probeNotify() -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    // Re-fetched inside each callback rather than captured: they arrive on a
    // background queue, and the center isn't `Sendable`.
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      print("bundle id:  \(Bundle.main.bundleIdentifier ?? "none")")
      print(
        "authorized: \(settings.authorizationStatus.rawValue) "
          + "(0=notDetermined 1=denied 2=authorized 3=provisional)")
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
        granted, error in
        print("request:    granted=\(granted) error=\(error?.localizedDescription ?? "nil")")
        guard granted else { exit(2) }
        let content = UNMutableNotificationContent()
        content.title = "Pier"
        content.body = "Claude Code started node · chrome-devtools-mcp"
        let request = UNNotificationRequest(identifier: "probe", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
          print("delivery:   \(error?.localizedDescription ?? "posted")")
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
      print("TIMEOUT — no callback in 45s")
      exit(3)
    }
    NSApp.run()
    exit(0)
  }

  private static func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
    return args[index + 1]
  }
}
