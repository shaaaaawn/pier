import XCTest

@testable import Pier

/// MCP servers named for what they are. Command lines are real ones from the
/// dev machine (home folder neutralised): 17 raw rows that were 6 servers.
final class MCPNamesTests: XCTestCase {
  func name(_ command: String) -> String? { MCPNames.identity(command: command)?.name }

  func testLauncherServerAndHelperShareOneName() {
    let launcher = "npm exec chrome-devtools-mcp@latest --isolated"
    let server = "chrome-devtools-mcp"
    let watchdog =
      "/Users/you/.nvm/versions/node/v24.16.0/bin/node /Users/you/.npm/_npx/15c6/node_modules/"
      + "chrome-devtools-mcp/build/src/telemetry/watchdog/main.js --parent-pid=920 --os-type=2"
    XCTAssertEqual(name(launcher), "Chrome DevTools")
    XCTAssertEqual(name(server), "Chrome DevTools")
    XCTAssertEqual(name(watchdog), "Chrome DevTools")
    XCTAssertEqual(MCPNames.identity(command: launcher)?.package, "chrome-devtools-mcp@latest")
  }

  func testScopedPackagesAndBinShims() {
    XCTAssertEqual(name("npm exec @agentdeskai/browser-tools-mcp@latest"), "Browser Tools")
    XCTAssertEqual(
      name("node /Users/you/.npm/_npx/662a/node_modules/.bin/browser-tools-mcp"), "Browser Tools")
    XCTAssertEqual(
      name("npm exec @just-every/mcp-screenshot-website-fast"), "Screenshot Website Fast")
    XCTAssertEqual(name("npx -y @modelcontextprotocol/server-github"), "GitHub")
  }

  /// `xurl mcp <url>`: the tool is the binary, whether run directly or via
  /// its node shim, and the URL's host says what it talks to.
  func testSubcommandServers() {
    let shim = "node /Users/you/.npm/_npx/c06c/node_modules/.bin/xurl mcp https://api.x.com/mcp"
    let binary =
      "/Users/you/.npm/_npx/c06c/node_modules/@xdevplatform/xurl/binary/xurl mcp https://api.x.com/mcp"
    XCTAssertEqual(name(shim), "X API")
    XCTAssertEqual(name(binary), "X API")
    XCTAssertEqual(MCPNames.identity(command: binary)?.package, "xurl · api.x.com")
  }

  /// "Application Support" has a space; the extension id names the server.
  func testClaudeExtensionsAndRunners() {
    XCTAssertEqual(
      name(
        "/Users/you/Library/Application Support/Claude/Claude Extensions/ant.dir.gh.blender.blender-mcp"
          + "/.venv/bin/python /Users/you/Library/Application Support/Claude/Claude Extensions/"
          + "ant.dir.gh.blender.blender-mcp/.venv/bin/blender-mcp"), "Blender")
    XCTAssertEqual(name("/opt/homebrew/bin/uv run blender-mcp"), "Blender")
    XCTAssertEqual(name("uvx mcp-server-fetch"), "Fetch")
  }

  func testScriptPathNamesTheFolderNotTheFile() {
    XCTAssertEqual(
      name("/opt/homebrew/bin/node /Users/you/x/chrome-devtools-mcp/build/index.js"),
      "Chrome DevTools")
  }

  /// A generic leftover names the host app instead of "Process".
  func testGenericNamesFallBackToTheHost() {
    XCTAssertEqual(name("Cursor Helper: mcp-process"), "Cursor MCP")
    XCTAssertEqual(name("/usr/local/bin/npm exec mcp-server"), "npm MCP")
  }

  /// One row per server, counted in servers: launcher → server → helper is
  /// one instance, not three.
  func testRowsGroupByServerAndCountInstances() {
    let ps = """
      100 dev npm exec chrome-devtools-mcp@latest --isolated
      101 dev chrome-devtools-mcp
      102 dev node /x/node_modules/chrome-devtools-mcp/build/src/telemetry/watchdog/main.js
      200 dev npm exec chrome-devtools-mcp@latest --isolated
      201 dev chrome-devtools-mcp
      300 dev /opt/homebrew/bin/uv run blender-mcp
      """
    let table = ProcessTable.parse(
      """
      1 0 launchd
      50 1 claude
      100 50 npm
      101 100 node
      102 101 node
      200 50 npm
      201 200 node
      300 50 uv
      """)
    let rows = ActivityParser.mcpEntries(fullPS: ps, table: table, cmux: nil)
    XCTAssertEqual(rows.map(\.name), ["Chrome DevTools", "Blender"])
    XCTAssertEqual(rows[0].pids.count, 5)
    XCTAssertEqual(rows[0].count, 2, "two servers, five processes")
    XCTAssertEqual(rows[0].subtitle, "chrome-devtools-mcp@latest")
    XCTAssertEqual(rows[1].count, 1)
  }
}
