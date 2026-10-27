import XCTest

@testable import Pier

final class ActivityTests: XCTestCase {
  // MARK: - Docker

  func testParseDockerPSWithPortsAndStatus() {
    let out =
      "web\tnginx:1.27\tUp 3 hours\t0.0.0.0:8080->80/tcp, :::8080->80/tcp\n"
      + "db\tpostgres:16\tUp 2 days (healthy)\t5432/tcp\n"
    let parsed = ActivityParser.parseDockerPS(out)
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(parsed[0].name, "web")
    // Status is condensed for the panel's width — see condenseStatus.
    XCTAssertEqual(parsed[0].detail, "nginx:1.27 · up 3h")
    XCTAssertEqual(parsed[1].detail, "postgres:16 · up 2d (healthy)")
    XCTAssertEqual(parsed[0].ports, [8080])
    XCTAssertEqual(parsed[1].ports, [])  // unpublished port exposes nothing
  }

  func testParsePublishedPortsDedupesAcrossFamilies() {
    XCTAssertEqual(
      ActivityParser.parsePublishedPorts(
        "0.0.0.0:8080->80/tcp, :::8080->80/tcp, 127.0.0.1:9229->9229/tcp"),
      [8080, 9229])
    XCTAssertEqual(ActivityParser.parsePublishedPorts("5432/tcp"), [])
  }

  // MARK: - Apple containers

  /// Verbatim `container list` output from apple/container 1.1.0 — nine
  /// columns (IP/CPUS/MEMORY/STARTED follow STATE), captured live rather than
  /// guessed, since the trailing columns shift STATE's index.
  func testParseContainerListRealOutput() {
    let out = """
      ID         IMAGE                           OS     ARCH   STATE    IP               CPUS  MEMORY   STARTED
      pier-test  docker.io/library/nginx:alpine  linux  arm64  running  192.168.65.2/24  4     1024 MB  2026-07-26T21:18:42Z
      """
    let parsed = ActivityParser.parseContainerList(out)
    XCTAssertEqual(parsed.count, 1, "header row must be skipped")
    XCTAssertEqual(parsed[0].name, "pier-test")
    XCTAssertEqual(parsed[0].detail, "docker.io/library/nginx:alpine · running")
    XCTAssertEqual(parsed[0].kind, .apple)
  }

  func testParseContainerListToleratesShortRows() {
    let out = """
      ID          IMAGE                        OS     ARCH   STATE    ADDR
      my-nginx    docker.io/library/nginx:1    linux  arm64  running  192.168.64.3
      sparse      some/image
      """
    let parsed = ActivityParser.parseContainerList(out)
    XCTAssertEqual(parsed.map(\.name), ["my-nginx", "sparse"])
    XCTAssertEqual(parsed[0].detail, "docker.io/library/nginx:1 · running")
    XCTAssertEqual(parsed[1].detail, "some/image")
  }

  // MARK: - MCP processes

  private func table(_ rows: [(Int32, Int32, String)]) -> ProcessTable {
    ProcessTable.parse(rows.map { "\($0.0) \($0.1) \($0.2)" }.joined(separator: "\n"))
  }

  func testMCPEntriesLabelGroupAndAttribute() {
    // Two mcp servers under a claude ancestor, one standalone, one root.
    let ps = """
        101 dev /opt/homebrew/bin/node /Users/s/x/chrome-devtools-mcp/build/index.js
        102 dev /opt/homebrew/bin/node /Users/s/y/chrome-devtools-mcp/build/index.js
        103 dev npm exec @modelcontextprotocol/server-github
        104 root /usr/libexec/mcp-daemon
        200 dev ps -axo pid=,user=,command=
      """
    let t = table([
      (101, 50, "node"), (102, 50, "node"), (50, 1, "claude"),
      (103, 1, "npm"), (104, 1, "mcp-daemon"),
    ])
    let entries = ActivityParser.mcpEntries(fullPS: ps, table: t, cmux: nil)
    XCTAssertEqual(entries.count, 3)

    // Named for the server, not the runtime (see MCPNamesTests).
    XCTAssertEqual(entries[0].name, "Chrome DevTools")
    XCTAssertEqual(entries[0].pids, [101, 102])
    XCTAssertEqual(entries[0].attribution, .harness("Claude Code"))

    XCTAssertEqual(entries[1].name, "GitHub")
    XCTAssertEqual(entries[1].attribution, .none)

    XCTAssertEqual(entries[2].attribution, .system)  // root-owned
  }

  func testMCPCommandExcludesDeepArgsAndFlagValues() {
    // The server itself: mcp token in the head.
    XCTAssertTrue(ActivityParser.isMCPCommand("node /x/chrome-devtools-mcp/build/index.js"))
    XCTAssertTrue(ActivityParser.isMCPCommand("npm exec -y chrome-devtools-mcp@latest"))
    // Chrome spawned BY the server: mcp only in a flag value.
    XCTAssertFalse(
      ActivityParser.isMCPCommand(
        "/applications/google chrome.app/contents/macos/google chrome"
          + " --user-data-dir=/x/chrome-devtools-mcp/chrome-profile"))
    // A harness CLI naming mcp tools deep in its args.
    XCTAssertFalse(
      ActivityParser.isMCPCommand(
        "claude --append-system-disclaimer use tools mcp__computer-use,mcp__session"))
  }

  /// Shell pipelines that merely quote "mcp" are not servers — this showed up
  /// live as `sed · MCP` while grepping Pier's own output.
  func testMCPCommandExcludesTextToolsQuotingMCP() {
    for command in [
      "sed -n /containers/,/mcp servers/p",
      "grep -n mcp sources/pier/activitymonitor.swift",
      "rg mcp-server",
      "ps -axo pid=,user=,command=",
      "/usr/bin/tail -f /tmp/mcp.log",
    ] {
      XCTAssertFalse(ActivityParser.isMCPCommand(command), "should not flag: \(command)")
    }
    // …but a real server whose path happens to include a tool-ish word still counts.
    XCTAssertTrue(ActivityParser.isMCPCommand("node /opt/grep-tools/mcp-server/index.js"))
  }

  func testMCPLabelPrefersMCPPathSegment() {
    let mcpish = { (s: String) in s.contains("mcp") || s.contains("modelcontextprotocol") }
    XCTAssertEqual(
      ActivityParser.mcpLabel(
        command: "/opt/homebrew/bin/node /a/mcp-filesystem/dist/index.js", mcpish: mcpish),
      "node · mcp-filesystem")
    XCTAssertEqual(
      ActivityParser.mcpLabel(
        command: "npm exec @modelcontextprotocol/server-github", mcpish: mcpish),
      "npm · server-github")
  }

  // MARK: - Grouping & search

  @MainActor
  func testActivityGroupsFilterAndOrder() {
    let activity = [
      ActivityEntry(kind: .mcp, name: "node · mcp-fs", detail: "cmd", pids: [1]),
      ActivityEntry(kind: .docker, name: "web", detail: "nginx · Up", ports: [8080]),
      ActivityEntry(kind: .apple, name: "builder", detail: "img · running"),
    ]
    let monitor = PortMonitor(fixture: [], activity: activity)
    let all = monitor.activityGroups(matching: "")
    XCTAssertEqual(all.map(\.kind), [.docker, .apple, .mcp])

    let filtered = monitor.activityGroups(matching: "nginx")
    XCTAssertEqual(filtered.count, 1)
    XCTAssertEqual(filtered[0].kind, .docker)
  }

  func testActivityEntryMatchesPortAndBadge() {
    let entry = ActivityEntry(
      kind: .docker, name: "web", detail: "nginx:1.27 · Up", ports: [8080])
    XCTAssertTrue(entry.matches("8080"))
    XCTAssertTrue(entry.matches("docker"))
    XCTAssertFalse(entry.matches("postgres"))
  }

  /// Each engine is named, so searching one doesn't drag in the other and
  /// neither heading reads as a subset of the other.
  func testEngineSectionsAreNamedAndSearchableSeparately() {
    XCTAssertEqual(ActivityKind.docker.sectionTitle, "Docker")
    XCTAssertEqual(ActivityKind.apple.sectionTitle, "Apple Containers")

    let apple = ActivityEntry(kind: .apple, name: "pier-web", detail: "nginx:alpine · running")
    let docker = ActivityEntry(kind: .docker, name: "data_redis", detail: "redis:8-alpine · Up")
    XCTAssertTrue(apple.matches("apple"))
    XCTAssertFalse(apple.matches("docker"))
    XCTAssertTrue(docker.matches("docker"))
    XCTAssertFalse(docker.matches("apple"))

    // The chip is the umbrella over both engines.
    XCTAssertEqual(PierFilter.containers.label, "Containers")
    XCTAssertEqual(PierFilter.containers.activityKinds, [.docker, .apple, .simulator])
  }
}

/// Stopped containers — the reason an idle machine looked empty before
/// `docker ps -a` / `container list --all`. Output below is verbatim from this
/// machine (four Compose containers stopped a few hours earlier).
final class StoppedContainerTests: XCTestCase {
  func testDockerStatusRunningDetection() {
    XCTAssertTrue(ActivityParser.dockerStatusIsRunning("Up 3 hours"))
    XCTAssertTrue(ActivityParser.dockerStatusIsRunning("Up 2 minutes (healthy)"))
    XCTAssertFalse(ActivityParser.dockerStatusIsRunning("Exited (0) 3 hours ago"))
    XCTAssertFalse(ActivityParser.dockerStatusIsRunning("Created"))
    XCTAssertFalse(ActivityParser.dockerStatusIsRunning("Paused"))
    XCTAssertFalse(ActivityParser.dockerStatusIsRunning("Restarting (1) 5 seconds ago"))
  }

  func testParsesStoppedDockerContainers() {
    let out = """
      acme_api\tacme-api\tExited (0) 3 hours ago\t
      data_redis\tredis:8-alpine\tExited (0) 3 hours ago\t
      data_mongo\tmongo:7.0.34\tExited (0) 3 hours ago\t
      data_postgres\tpostgres:16-alpine\tUp 4 minutes\t0.0.0.0:5432->5432/tcp
      """
    let entries = ActivityParser.parseDockerPS(out)
    XCTAssertEqual(entries.count, 4)
    XCTAssertEqual(
      entries.filter { !$0.isRunning }.map(\.name),
      ["acme_api", "data_redis", "data_mongo"])
    let running = entries.first { $0.isRunning }
    XCTAssertEqual(running?.name, "data_postgres")
    XCTAssertEqual(running?.ports, [5432])
  }

  func testParsesAppleStateColumn() {
    let out = """
      ID          IMAGE                       OS     ARCH   STATE     ADDR
      buildkit    ghcr.io/example/buildkit    linux  arm64  running   192.168.64.2
      scratch     docker.io/library/alpine    linux  arm64  stopped   —
      """
    let entries = ActivityParser.parseContainerList(out)
    XCTAssertEqual(entries.map(\.name), ["buildkit", "scratch"])
    XCTAssertEqual(entries.map(\.isRunning), [true, false])
    XCTAssertTrue(entries[1].detail.contains("stopped"))
  }

  /// A section of stopped containers must not read like a section of running
  /// ones — the header count is qualified.
  func testGroupReportsStoppedCount() {
    let group = ActivityGroup(
      kind: .docker,
      entries: [
        ActivityEntry(kind: .docker, name: "a", detail: "", isRunning: true),
        ActivityEntry(kind: .docker, name: "b", detail: "", isRunning: false),
        ActivityEntry(kind: .docker, name: "c", detail: "", isRunning: false),
      ])
    XCTAssertEqual(group.entryCount, 3)
    XCTAssertEqual(group.stoppedCount, 2)
  }
}

/// Docker writes Status for an 80-column terminal; the panel is 340pt wide.
final class StatusCondensationTests: XCTestCase {
  func testCondensesRealDockerStatuses() {
    let cases = [
      ("Up 28 hours (healthy)", "up 28h (healthy)"),
      ("Up 3 hours", "up 3h"),
      ("Up 2 minutes", "up 2m"),
      ("Exited (0) 3 hours ago", "exited 0, 3h ago"),
      ("Exited (137) 2 days ago", "exited 137, 2d ago"),
      ("Up Less than a second (health: starting)", "up <1s (starting)"),
      ("Up 5 months", "up 5mo"),
      ("Created", "Created"),
      // Docker's fuzzy durations. Shortening " minute" first turned
      // "Up About a minute" into "up About am", seen live on a real container.
      ("Up About a minute (healthy)", "up ~1m (healthy)"),
      ("Up About an hour", "up ~1h"),
      ("Exited (0) about a minute ago", "exited 0, about 1m ago"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(ActivityParser.condenseStatus(input), expected, "for \(input)")
    }
  }

  /// Condensing is display-only — it must not change what counts as running.
  func testCondensationDoesNotAffectRunningDetection() {
    let out = "data_postgres\tpostgres:16-alpine\tExited (0) 4 hours ago\t"
    let entry = ActivityParser.parseDockerPS(out).first
    XCTAssertEqual(entry?.detail, "postgres:16-alpine · exited 0, 4h ago")
    XCTAssertEqual(entry?.isRunning, false)
  }
}
