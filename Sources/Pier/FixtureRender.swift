import AppKit
import SwiftUI

/// `Pier --render-fixture <out.png>`: renders PortListView with rich fixture
/// data to a PNG and exits before entering the app loop. Permanently useful
/// for UI design iteration without touching the live menu bar.
enum FixtureRenderer {
  /// `--render-fixture <out.png> [scope]` — scope optionally preselects a
  /// filter chip (all/web/ports/containers/mcp) so each state is gradeable.
  @MainActor
  static func render(to path: String, scope: String? = nil) -> Never {
    render(to: path, entries: FixtureData.entries, scope: scope)
  }

  /// `--render-fixture-activity`: a short port list so the Docker/Containers/
  /// MCP sections land above the fold for grading.
  @MainActor
  static func renderActivity(to path: String) -> Never {
    render(to: path, entries: Array(FixtureData.entries.prefix(3)), scope: nil)
  }

  /// `--render-fixture-expanded <out.png>`: the panel with a row's preview
  /// already open, so the expanded layout (address bar + monitor-aspect card)
  /// is gradeable without clicking the live menu bar.
  @MainActor
  static func renderExpanded(to path: String) -> Never {
    let entries = Array(FixtureData.entries.prefix(6))
    // Must be a *standalone* row: a clustered entry's children are hidden
    // until the cluster is expanded, so its preview wouldn't render.
    var perPid: [Int32: Int] = [:]
    for entry in entries { perPid[entry.pid, default: 0] += 1 }
    let target = entries.first { $0.previewURL != nil && perPid[$0.pid] == 1 }
    render(to: path, entries: entries, scope: "all", expanded: target?.id)
  }

  /// `--render-fixture-idle <out.png>`: engines installed but with **no
  /// containers** — the state where the sections used to vanish, taking their
  /// start/stop/prune menus with them.
  @MainActor
  static func renderIdleEngines(to path: String) -> Never {
    let mcpOnly = FixtureData.activity.filter { $0.kind == .mcp }
    render(
      to: path, entries: Array(FixtureData.entries.prefix(2)), scope: "all",
      activity: mcpOnly)
  }

  /// `--render-fixture-down <out.png>`: both engines installed but **not
  /// running** — the state that used to say so three times over (pinned banner,
  /// section row, and a "0" count that claimed zero containers we hadn't
  /// counted). One statement per engine now, in the section.
  @MainActor
  static func renderEnginesDown(to path: String) -> Never {
    let mcpOnly = FixtureData.activity.filter { $0.kind == .mcp }
    render(
      to: path, entries: Array(FixtureData.entries.prefix(2)), scope: "containers",
      activity: mcpOnly, dockerState: .unreachable, appleState: .unreachable)
  }

  /// `--render-fixture-narrow <out.png>`: the list at the **minimum** panel
  /// width (340pt). Everything else renders at the 440pt default, which hides
  /// crowding in the chip row — and a panel really can sit at the minimum (mine
  /// does). This is where a new chip or control gets caught overflowing.
  @MainActor
  static func renderNarrow(to path: String) -> Never {
    render(to: path, entries: Array(FixtureData.entries.prefix(4)), scope: "all",
      width: PanelSize.minWidth)
  }

  /// `--render-fixture-events <out.png>`: the start/stop feed, with the actor
  /// column that is the whole point of it.
  @MainActor
  static func renderEvents(to path: String) -> Never {
    render(
      to: path, entries: Array(FixtureData.entries.prefix(3)), scope: "all",
      events: FixtureData.events, showEvents: true)
  }

  /// `--render-fixture-logs <out.png>`: the panel with a Docker row's log tail
  /// open, so the log drawer is gradeable without a live container.
  @MainActor
  static func renderLogs(to path: String) -> Never {
    let entries = Array(FixtureData.entries.prefix(2))
    let target = FixtureData.activity.first { $0.kind == .docker }
    render(to: path, entries: entries, scope: "all", expanded: target?.id, mode: .logs)
  }

  @MainActor
  private static func render(
    to path: String, entries: [PortEntry], scope: String?, expanded: String? = nil,
    mode: RowExpansion.Mode = .preview, activity: [ActivityEntry]? = nil,
    dockerState: EngineState = .ready, appleState: EngineState = .ready,
    events: [PierEvent] = [], showEvents: Bool = false, width: CGFloat? = nil
  ) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    // The chips read @AppStorage, so seeding the default selects a state.
    if let scope, PierFilter(rawValue: scope) != nil {
      UserDefaults.standard.set(scope, forKey: "listFilter")
    }

    let monitor = PortMonitor(
      fixture: entries, activity: activity ?? FixtureData.activity,
      history: FixtureData.history, dockerState: dockerState, appleState: appleState,
      events: events)

    // Host in a real (offscreen) window and snapshot via AppKit — ImageRenderer
    // cannot rasterize AppKit-backed controls (buttons, TextField) and draws
    // placeholder glyphs instead.
    let hostingView = NSHostingView(
      rootView: PortListView(
        initialExpandedID: expanded, initialMode: mode, initialShowEvents: showEvents)
        .environmentObject(monitor))
    let size = NSSize(
      width: width ?? PortListView.panelWidth, height: PortListView.panelHeight)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = hostingView
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    hostingView.layoutSubtreeIfNeeded()

    guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      FileHandle.standardError.write("render-fixture: bitmap rep failed\n".data(using: .utf8)!)
      exit(1)
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      FileHandle.standardError.write("render-fixture: png encoding failed\n".data(using: .utf8)!)
      exit(1)
    }
    do {
      try png.write(to: URL(fileURLWithPath: path))
    } catch {
      FileHandle.standardError.write("render-fixture: \(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }
    print("wrote \(path)")
    exit(0)
  }

  /// `Pier --probe-viewport <url> [out.png]`: loads a URL through the real
  /// PreviewController at the real card width, prints the CSS viewport the
  /// page actually sees, and optionally snapshots the webview. Fixture
  /// renders can't verify this — they swap in a static placeholder — so this
  /// is the only check that the desktop-viewport zoom really took effect.
  @MainActor
  static func probeViewport(url: String, out: String?) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    guard let target = URL(string: url) else {
      FileHandle.standardError.write("probe-viewport: bad url\n".data(using: .utf8)!)
      exit(1)
    }

    let cardWidth = PortListView.panelWidth - 24
    let controller = PreviewController()
    let viewport = PreviewViewport.desktop
    let height = (cardWidth * viewport.aspect).rounded()
    controller.webView.frame = NSRect(x: 0, y: 0, width: cardWidth, height: height)
    controller.applyViewport(viewport, cardWidth: cardWidth)

    // Host offscreen so layout/paint actually run.
    let window = NSWindow(
      contentRect: controller.webView.frame, styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = controller.webView
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)

    controller.load(target)

    // Poll for the load to settle, then report.
    func check(_ attempt: Int) {
      guard attempt < 40 else {
        print("probe-viewport: timed out (state=\(controller.state))")
        exit(1)
      }
      if case .loaded = controller.state {
        controller.probeViewport { measured in
          print("card: \(Int(cardWidth))×\(Int(height))pt")
          print("pageZoom: \(String(format: "%.3f", controller.webView.pageZoom))")
          print("page sees: \(measured)")
          if let out, let rep = controller.webView.bitmapImageRepForCachingDisplay(
            in: controller.webView.bounds) {
            controller.webView.cacheDisplay(in: controller.webView.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
              try? png.write(to: URL(fileURLWithPath: out))
              print("wrote \(out)")
            }
          }
          exit(0)
        }
        return
      }
      if case .failed(let message) = controller.state {
        print("probe-viewport: load failed — \(message)")
        exit(1)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check(attempt + 1) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check(0) }
    NSApplication.shared.run()
    exit(0)
  }

  /// `Pier --render-fixture-preview <out.png>`: renders the preview component
  /// in all three states (loaded placeholder, loading, error) so the chrome
  /// can be graded without a live WKWebView.
  @MainActor
  static func renderPreview(to path: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    let entry = FixtureData.entries.first { $0.port == 3000 }!
    let view = VStack(alignment: .leading, spacing: 4) {
      Text("loaded")
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.leading, 14)
      PortPreviewView(entry: entry, fixtureState: .loaded)
      Text("loading")
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.leading, 14)
      PortPreviewView(entry: entry, fixtureState: .loading)
      Text("error")
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.leading, 14)
      PortPreviewView(
        entry: entry,
        fixtureState: .failed("Could not connect to the server.")
      )
    }
    .padding(.vertical, 8)
    .frame(width: PortListView.panelWidth)
    .background(VisualEffectBackground())

    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: PortListView.panelWidth, height: 1160)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: PortListView.panelWidth, height: 1160),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = hostingView
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    hostingView.layoutSubtreeIfNeeded()

    guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      FileHandle.standardError.write("render-fixture-preview: bitmap rep failed\n".data(using: .utf8)!)
      exit(1)
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      FileHandle.standardError.write("render-fixture-preview: png encoding failed\n".data(using: .utf8)!)
      exit(1)
    }
    do {
      try png.write(to: URL(fileURLWithPath: path))
    } catch {
      FileHandle.standardError.write("render-fixture-preview: \(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }
    print("wrote \(path)")
    exit(0)
  }
}

/// Mirrors the real mess: a Cursor cluster, a cmux workspace where one pid
/// holds five workerd ports, a Codex pair, IPv6-only and wildcard binds, an
/// unattributed dev server, and system services.
enum FixtureData {
  private static func e(
    _ pid: Int32, _ port: Int, _ name: String,
    proto: PortProtocol = .tcp,
    user: String = "shawn",
    binds: [String] = ["127.0.0.1"],
    attr: Attribution,
    cpu: Double = 0.4,
    rssMB: Int = 120
  ) -> PortEntry {
    PortEntry(
      pid: pid, port: port, proto: proto, processName: name, user: user,
      bindAddresses: binds, attribution: attr,
      usage: Usage(cpu: cpu, rssKB: rssMB * 1024)
    )
  }

  /// Sample log output for the log-panel fixture render — includes a warning
  /// and an error line so the severity tinting is gradeable.
  static let logLines: [String] = [
    "2026-07-26T21:40:02.113Z  nginx/1.27.3  starting worker processes",
    "2026-07-26T21:40:02.118Z  worker process 31 started",
    "127.0.0.1 - - [26/Jul/2026:21:40:11] \"GET / HTTP/1.1\" 200 1547",
    "127.0.0.1 - - [26/Jul/2026:21:40:11] \"GET /assets/app.css HTTP/1.1\" 200 8231",
    "WARN  upstream response is buffered to a temporary file /var/cache/nginx/0000001",
    "127.0.0.1 - - [26/Jul/2026:21:40:14] \"GET /api/health HTTP/1.1\" 200 17",
    "ERROR connect() failed (111: Connection refused) while connecting to upstream",
    "127.0.0.1 - - [26/Jul/2026:21:40:15] \"GET /api/items HTTP/1.1\" 502 494",
    "2026-07-26T21:40:19.006Z  reopening logs",
    "127.0.0.1 - - [26/Jul/2026:21:40:22] \"GET / HTTP/1.1\" 200 1547",
  ]

  /// Deterministic CPU series per fixture pid — a mix of idle, spiky, ramping
  /// and pegged so the sparkline's shape and tint are both gradeable.
  static let history: UsageHistory = {
    var history = UsageHistory()
    let shapes: [Int32: [Double]] = [
      8120: [2, 3, 2, 4, 12, 30, 22, 9, 4, 3, 2, 2, 3, 2],  // Cursor: spiky
      9122: [40, 44, 52, 61, 58, 70, 76, 81, 88, 92, 96, 99, 97, 94],  // workerd: hot
      55105: [1, 1, 2, 1, 1, 3, 8, 14, 18, 24, 20, 16, 12, 9],  // node: ramping
      4410: [0, 0, 0.2, 0, 0, 0.1, 0, 0, 0.3, 0, 0, 0, 0.1, 0],  // codex: idle
      777: [5, 6, 5, 7, 6, 5, 6, 7, 6, 5, 6, 6, 5, 6],  // caddy: flat
      5396: [12, 18, 9, 22, 31, 27, 19, 11, 8, 14, 21, 17, 13, 10],  // mcp: busy
    ]
    // Replay sample-by-sample so the ring buffer is exercised, not hand-set.
    for step in 0..<UsageHistory.window {
      var round: [Int32: Double] = [:]
      for (pid, series) in shapes {
        round[pid] = series[step % series.count]
      }
      history.record(round)
    }
    return history
  }()

  static let entries: [PortEntry] = [
    // Cursor — two ports on one pid (cluster) plus a helper.
    e(8120, 49221, "Cursor", attr: .harness("Cursor"), cpu: 2.4, rssMB: 310),
    e(8120, 49224, "Cursor", attr: .harness("Cursor")),
    e(8231, 51731, "Cursor Helper (", attr: .harness("Cursor")),

    // cmux · Idle Screens — one workerd pid holding five Vite dev ports.
    e(9122, 60342, "workerd", attr: .cmux(workspace: "Idle Screens", surface: "make dev screens", harness: nil), cpu: 94, rssMB: 890),
    e(9122, 60345, "workerd", attr: .cmux(workspace: "Idle Screens", surface: "make dev screens", harness: nil)),
    e(9122, 60350, "workerd", attr: .cmux(workspace: "Idle Screens", surface: "make dev screens", harness: nil)),
    e(9122, 60352, "workerd", attr: .cmux(workspace: "Idle Screens", surface: "make dev screens", harness: nil)),
    e(9122, 60353, "workerd", attr: .cmux(workspace: "Idle Screens", surface: "make dev screens", harness: nil)),

    // cmux with a harness behind it — node dev server under a Kimi surface.
    e(55105, 3000, "node", binds: ["::1", "127.0.0.1"],
       attr: .cmux(workspace: "Personal Agent", surface: "Kimi", harness: "Kimi"), cpu: 9, rssMB: 220),

    // Codex — two ports on one pid.
    e(4410, 8765, "codex", attr: .harness("Codex"), cpu: 0, rssMB: 64),
    e(4410, 8766, "codex", binds: ["0.0.0.0"], attr: .harness("Codex")),

    // Unattributed dev servers: IPv6-only and wildcard binds.
    e(777, 8080, "caddy", binds: ["::1"], attr: .none),
    e(6601, 8931, "python3.1", binds: ["*"], attr: .none),

    // System services.
    e(123, 5353, "mDNSRespo", proto: .udp, user: "_mdnsresponder", binds: ["*"], attr: .system),
    e(98, 80, "httpd", user: "root", binds: ["*"], attr: .system),
  ]

  /// Background activity: a docker stack (one with published ports), an Apple
  /// container, and MCP servers — one grouped ×8, one cmux-attributed.
  /// Ordered newest-first, the way the monitor stores them.
  static let events: [PierEvent] = {
    // Offsets from *now*, not a fixed instant: the feed renders relative times,
    // so a frozen 2023 date grades as "2 yrs, 8 mths" and tells you nothing
    // about how "12 seconds" will look.
    let now = Date()
    func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    return [
      PierEvent(
        date: ago(12), action: .stopped, subject: .mcp("node · chrome-devtools-mcp"),
        actor: .harness("Claude Code"), count: 3),
      PierEvent(
        date: ago(48), action: .started, subject: .port(5173, process: "node"),
        actor: .cmux(workspace: "Idle Screens", surface: "dev", harness: "Claude Code")),
      PierEvent(
        date: ago(120), action: .stopped, subject: .container(.docker, "data_redis"),
        actor: .none, selfInitiated: true),
      PierEvent(
        date: ago(240), action: .started, subject: .container(.docker, "data_postgres"),
        actor: .none),
      PierEvent(
        date: ago(600), action: .stopped, subject: .port(3001, process: "node · ntl"),
        actor: .cmux(workspace: "Hermosa Server", surface: "dev", harness: nil)),
    ]
  }()

  static let activity: [ActivityEntry] = [
    ActivityEntry(
      kind: .docker, name: "hermosa_mcp_server",
      detail: "hermosa-server-mcp-server · Up 28 hours (healthy)", ports: [8080]),
    ActivityEntry(
      kind: .docker, name: "data_postgres",
      detail: "postgres:16-alpine · Up 28 hours (healthy)", ports: [5432]),
    ActivityEntry(
      kind: .docker, name: "data_redis",
      detail: "redis:8-alpine · Up 28 hours (healthy)"),
    // Two stopped containers — the state `docker ps` alone can't see. They
    // render dimmed with a Start button, so the fixture grades both treatments.
    ActivityEntry(
      kind: .docker, name: "data_mongo",
      detail: "mongo:7.0.34 · Exited (0) 3 hours ago", isRunning: false),
    ActivityEntry(
      kind: .apple, name: "builder-arm64",
      detail: "ghcr.io/apple/container-builder · running"),
    ActivityEntry(
      kind: .apple, name: "scratch-alpine",
      detail: "docker.io/library/alpine · stopped", isRunning: false),
    ActivityEntry(
      kind: .mcp, name: "node · chrome-devtools-mcp",
      detail: "node /Users/you/.npm/_npx/…/chrome-devtools-mcp/build/src/index.js",
      pids: [5396, 5397, 5398, 5399, 5400, 5401, 5402, 5403],
      attribution: .harness("Claude Code"),
      usage: Usage(cpu: 13, rssKB: 1_450 * 1024)),
    ActivityEntry(
      kind: .mcp, name: "uv · blender-mcp",
      detail: "uv run blender-mcp", pids: [3634],
      attribution: .cmux(workspace: "Metaquarium", surface: "Claude", harness: "Claude Code")),
    ActivityEntry(
      kind: .mcp, name: "npm · server-github",
      detail: "npm exec @modelcontextprotocol/server-github", pids: [7801]),
  ]
}

