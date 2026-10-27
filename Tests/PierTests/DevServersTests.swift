import XCTest

@testable import Pier

/// Dev-server detection. Command lines are shaped on a real machine's
/// listeners (names neutralised): of 19 listening processes, three were dev
/// servers — and the noise is the part worth pinning, because a false "dev
/// server" is worse than a missed one.
final class DevServersTests: XCTestCase {
  let home = "/Users/you"

  let tree = """
      1     0 0 1 launchd
    100     1 0 1 zsh
    101   100 0 1 node
    200     1 0 1 claude
    201   200 0 1 node
    202   201 0 1 workerd
    203   201 0 1 workerd
    300     1 0 1 node
    400     1 0 1 Google Chrome for Testing
    500     1 0 1 node
    600     1 0 1 adb
    700     1 0 1 Google Drive
    800   100 0 1 npm
    801   800 0 1 node
    900   100 0 1 python3.11
    """

  var commands: [Int32: String] {
    [
      101: "ng serve (app)",
      200:
        "/Users/you/Library/Application Support/Claude/claude.app/Contents/MacOS/claude --output-format stream-json",
      201:
        "/Users/you/.nvm/versions/node/v24/bin/node --no-warnings /Users/you/code/api/node_modules/wrangler/wrangler-dist/cli.js dev",
      202:
        "/Users/you/code/api/node_modules/@cloudflare/workerd-darwin-arm64/bin/workerd serve --binary --experimental --socket-addr=entry=localhost:8782 --external-addr=loopback=127.0.0.1:65263 --inspector-addr=127.0.0.1:9229",
      203:
        "/Users/you/code/api/node_modules/@cloudflare/workerd-darwin-arm64/bin/workerd serve --binary --socket-addr=entry=127.0.0.1:0 --inspector-addr=127.0.0.1:65284",
      300: "node scripts/planner/server.mjs",
      400:
        "/Users/you/.cache/puppeteer/chrome/mac_arm-156/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --remote-debugging-port=0",
      500: "node /Users/you/.npm/_npx/abc/node_modules/.bin/browser-tools-mcp",
      600: "adb -L tcp:5037 fork-server server --reply-fd 4",
      700: "/Applications/Google Drive.app/Contents/MacOS/Google Drive --single_process",
      800: "npm run dev",
      801: "node /Users/you/code/site/node_modules/.bin/vite --port 5173",
      900: "python3.11 -m http.server 8000",
    ]
  }

  let directories: [Int32: String] = [
    101: "/Users/you/code/store/app", 202: "/Users/you/code/api", 203: "/Users/you/code/api",
    300: "/Users/you/code/estate", 500: "/Users/you", 801: "/Users/you/code/site",
    900: "/Users/you/code/notes",
  ]

  func classify(_ pid: Int32, _ port: Int) -> DevServer? {
    let table = ProcessTable.parse(tree)
    return DevServers.classify(
      port: port, chain: table.chain(from: pid), commands: commands,
      directory: { self.directories[$0] },
      project: { ProjectInfo(root: $0, name: URL(fileURLWithPath: $0).lastPathComponent) },
      home: home)
  }

  // MARK: - What it finds

  func testAngularIsNamedFromItsRetitledProcess() {
    // `ng serve` renames its process; ps still calls it node.
    XCTAssertEqual(
      classify(101, 4200),
      DevServer(framework: "Angular", project: "app", projectPath: "/Users/you/code/store/app"))
  }

  func testWorkerdEntrySocketIsTheWranglerServer() {
    XCTAssertEqual(classify(202, 8782)?.framework, "Wrangler")
    XCTAssertEqual(classify(202, 8782)?.project, "api")
  }

  func testAFrameworkNamedByTheBinaryPath() {
    XCTAssertEqual(classify(801, 5173)?.framework, "Vite")
  }

  func testAPlainScriptInAProjectIsADevServer() {
    XCTAssertEqual(classify(300, 4173)?.framework, "Node")
    XCTAssertEqual(classify(900, 8000)?.framework, "Python http.server")
  }

  // MARK: - What it rules out

  func testNoiseIsNeverADevServer() {
    XCTAssertNil(classify(400, 56112), "Chrome for Testing's debug port")
    XCTAssertNil(classify(500, 3025), "an MCP server")
    XCTAssertNil(classify(200, 54297), "the agent harness's own socket")
    XCTAssertNil(classify(600, 5037), "adb")
    XCTAssertNil(classify(700, 7679), "an app bundle")
  }

  func testDevToolPlumbingIsNotTheServer() {
    XCTAssertNil(classify(202, 9229), "workerd's inspector")
    XCTAssertNil(classify(202, 65263), "workerd's loopback socket")
    XCTAssertNil(classify(203, 53097), "wrangler's internal worker (entry :0)")
    XCTAssertNil(classify(201, 65263), "wrangler's own proxy")
  }

  func testNodeInspectorPorts() {
    XCTAssertTrue(DevServers.isInternalPort(9229, command: "node --inspect server.js"))
    XCTAssertTrue(DevServers.isInternalPort(9333, command: "node --inspect=127.0.0.1:9333 a.js"))
    XCTAssertFalse(DevServers.isInternalPort(3000, command: "node --inspect server.js"))
  }

  /// A runtime sitting in ~ with no project is some tool's helper, not yours.
  func testScriptInHomeIsNotADevServer() {
    let table = ProcessTable.parse("10 1 0 1 node")
    XCTAssertNil(
      DevServers.classify(
        port: 7000, chain: table.chain(from: 10), commands: [10: "node helper.js"],
        directory: { _ in self.home }, project: { _ in nil }, home: home))
  }

  // MARK: - Projects

  func testSameNamedProjectsAreToldApart() {
    let a = DevServer(framework: "Wrangler", project: "api", projectPath: "/Users/you/lanes/b/api")
    let b = DevServer(framework: "Wrangler", project: "api", projectPath: "/Users/you/lanes/f/api")
    let c = DevServer(framework: "Vite", project: "site", projectPath: "/Users/you/code/site")
    let out = DevServers.disambiguate([a, nil, b, c])
    XCTAssertEqual(out.map { $0?.project }, ["api (b)", nil, "api (f)", "site"])
  }

  /// Same name *and* same parent folder name: one folder isn't enough, so
  /// the label grows until the two differ.
  func testSameNamedProjectsWithSameParentNameGoDeeper() {
    let a = DevServer(framework: "Wrangler", project: "api", projectPath: "/Users/you/lanes/a/api")
    let b = DevServer(
      framework: "Wrangler", project: "api", projectPath: "/Users/you/scratch/a/api")
    XCTAssertEqual(
      DevServers.disambiguate([a, b]).map { $0?.project }, ["api (lanes/a)", "api (scratch/a)"])
  }

  func testProjectRootAndManifestName() {
    let files: Set<String> = ["/Users/you/code/store/package.json"]
    let info = DevServers.readProject(
      "/Users/you/code/store/app", home: home, fileExists: { files.contains($0) },
      readFile: {
        $0 == "/Users/you/code/store/package.json" ? Data(#"{"name":"storefront"}"#.utf8) : nil
      })
    XCTAssertEqual(info, ProjectInfo(root: "/Users/you/code/store", name: "storefront"))
  }

  /// No marker anywhere up to ~: the folder itself names it.
  func testProjectWithoutMarkersIsTheFolder() {
    let info = DevServers.readProject(
      "/Users/you/code/estate", home: home, fileExists: { _ in false }, readFile: { _ in nil })
    XCTAssertEqual(info?.name, "estate")
  }

  // MARK: - Scope

  func testDevScopeShowsOnlyDevServersGroupedByProject() {
    var vite = PortEntry(
      pid: 1, port: 5173, proto: .tcp, processName: "node", user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .harness("Claude Code"))
    vite.dev = DevServer(framework: "Vite", project: "site")
    let chrome = PortEntry(
      pid: 2, port: 56_000, proto: .tcp, processName: "Google Chrome for Testing", user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .harness("Claude Code"))
    let visible = PortMonitor.visibleEntries([vite, chrome], filter: .dev, hideSystem: false)
    XCTAssertEqual(visible.map(\.port), [5173])
    let groups = PortMonitor.buildGroups(entries: visible, matching: "", byProject: true)
    XCTAssertEqual(groups.map(\.title), ["site"])
    XCTAssertTrue(groups[0].isProject)
    XCTAssertTrue(vite.matches("vite"), "search finds the framework")
  }
}
