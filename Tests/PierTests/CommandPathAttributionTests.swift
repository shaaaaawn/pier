import XCTest

@testable import Pier

/// Harness detection from a full command line. Needed because most agent CLIs
/// run as `node <path>/cli.js` or `python -m <pkg>`, where `ps ucomm` is only
/// ever "node"/"python3" and the path is the sole clue.
final class CommandPathAttributionTests: XCTestCase {
  func testDetectsWrapperStyleHarnesses() {
    let cases: [(String, String)] = [
      ("node /Users/s/.npm/_npx/abc/node_modules/kimi-code/dist/cli.js", "Kimi"),
      ("/Users/s/.local/bin/agy --continue", "Antigravity"),
      ("node /opt/homebrew/lib/node_modules/opencode/bin/opencode.js", "OpenCode"),
      ("python3 -m openhands.core.main", "OpenHands"),
      ("node /Users/s/x/node_modules/@anthropic-ai/claude-code/cli.js", "Claude Code"),
      ("/Applications/Cursor.app/Contents/Resources/app/bin/cursor-agent", "Cursor"),
      ("node /Users/s/.factory-droid/bin/droid.js", "Factory Droid"),
    ]
    for (command, expected) in cases {
      XCTAssertEqual(
        Attributor.harnessLabel(fromCommand: command), expected,
        "failed to identify: \(command)")
    }
  }

  /// The trap that makes naive path matching worse than none: this machine has
  /// `~/code/` and `~/code/pi-workflow`, so matching generic tokens inside
  /// paths would label every dev server "VS Code" or "Pi".
  func testGenericTokensNeverMatchInsidePaths() {
    let innocent = [
      "node /Users/you/code/monorepo/web/node_modules/.bin/vite --port 5182",
      "python3 /Users/you/code/pi-workflow/server.py",
      "node /Users/you/code/amp-experiments/server.js",
      "/Users/you/code/zed-notes/bin/serve",
      "node /Users/you/code/warp-drive/dev.js",
    ]
    for command in innocent {
      XCTAssertNil(
        Attributor.harnessLabel(fromCommand: command),
        "false positive on an ordinary project path: \(command)")
    }
  }

  func testSegmentMatchingRespectsWordBoundaries() {
    XCTAssertTrue(Attributor.segmentMatches("kimi-code", token: "kimi-code"))
    XCTAssertTrue(Attributor.segmentMatches("kimi-code@1.2.0", token: "kimi-code"))
    XCTAssertTrue(Attributor.segmentMatches("claude-code", token: "claude-code"))
    // Embedded in a longer word is a different thing.
    XCTAssertFalse(Attributor.segmentMatches("mykimicodex", token: "kimi-code"))
    XCTAssertFalse(Attributor.segmentMatches("opencoded", token: "opencode"))
  }

  /// Name match wins over path match, and both beat the launcher.
  func testAttributionPrefersTheProcessOverItsPath() {
    let table = ProcessTable.parse("300 200 node\n200 1 bash")
    let commands: [Int32: String] = [
      300: "node /Users/s/.npm/_npx/x/node_modules/kimi-code/dist/cli.js --port 4000"
    ]
    let entry = PortEntry(
      pid: 300, port: 4000, proto: .tcp, processName: "node", user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .none)
    XCTAssertEqual(
      Attributor.attribute(entry: entry, table: table, cmux: nil, commands: commands),
      .harness("Kimi"),
      "a bare `node` process must be identified by its command path")
  }

  /// Without the command map nothing changes — path detection is additive.
  func testUnknownProcessStaysUnattributed() {
    let table = ProcessTable.parse("300 200 node\n200 1 bash")
    let entry = PortEntry(
      pid: 300, port: 4000, proto: .tcp, processName: "node", user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .none)
    XCTAssertEqual(Attributor.attribute(entry: entry, table: table, cmux: nil), Attribution.none)
  }

  func testAncestorCommandPathCountsToo() {
    // A dev server spawned *by* a harness: the child is plain node, the parent
    // carries the identifying path.
    let table = ProcessTable.parse("400 300 node\n300 1 node")
    let commands: [Int32: String] = [
      400: "node /Users/s/project/server.js",
      300: "node /Users/s/.local/share/opencode/bin/opencode.js",
    ]
    let entry = PortEntry(
      pid: 400, port: 5000, proto: .tcp, processName: "node", user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .none)
    XCTAssertEqual(
      Attributor.attribute(entry: entry, table: table, cmux: nil, commands: commands),
      .harness("OpenCode"))
  }

  func testPathOnlyRulesAreOptIn() {
    // Generic rules must carry no path tokens at all.
    for rule in harnessTable where ["code", "pi", "amp", "zed", "warp"].contains(rule.token) {
      XCTAssertTrue(
        rule.pathTokens.isEmpty,
        "\(rule.token) is too generic for path matching but declares pathTokens")
    }
  }
}

/// cmux's socket refuses outside processes by default; Pier must report that
/// rather than look like cmux isn't installed.
final class CmuxAccessTests: XCTestCase {
  func testDetectsAccessDenied() {
    XCTAssertTrue(
      CmuxAccess.isAccessDenied(
        "Error: ERROR: Access denied - only processes started inside cmux can connect"))
    XCTAssertFalse(CmuxAccess.isAccessDenied("workspace:1\tAcme Web"))
  }

  func testStatusClassification() {
    let denied = ProcessRunner.Result(
      stdout: "", stderr: "ERROR: Access denied - only processes started inside cmux can connect",
      exitCode: 1, timedOut: false)
    XCTAssertEqual(CmuxAccess.status(from: denied) { 0 }, .accessDenied)

    let ok = ProcessRunner.Result(stdout: "rows", stderr: "", exitCode: 0, timedOut: false)
    XCTAssertEqual(CmuxAccess.status(from: ok) { 3 }, .connected(workspaces: 3))

    XCTAssertEqual(
      CmuxAccess.status(from: nil) { 0 }, .failed("could not launch the cmux CLI"))
  }

  /// Not-yet-configured and configured-but-not-reloaded are the same refusal
  /// with completely different fixes, so the advice has to differ. Driven by an
  /// explicit mode rather than the live config, or the test would pass or fail
  /// depending on the machine it runs on.
  func testDeniedAdviceDependsOnTheConfiguredMode() {
    let notConfigured = CmuxAccess.deniedDetail(configuredMode: "cmuxOnly")
    XCTAssertTrue(notConfigured.contains("socketControlMode"), "must name the setting")
    XCTAssertTrue(notConfigured.contains("allowAll"), "must name the value that enables it")

    let needsRestart = CmuxAccess.deniedDetail(configuredMode: "allowAll")
    XCTAssertTrue(
      needsRestart.lowercased().contains("reopen cmux")
        || needsRestart.lowercased().contains("restart"),
      "when already configured, the fix is restarting cmux")
    XCTAssertNotEqual(
      CmuxAccess.deniedHint(configuredMode: "allowAll"),
      CmuxAccess.deniedHint(configuredMode: "cmuxOnly"))
  }

  func testQuietWhenThereIsNothingToReport() {
    XCTAssertNotNil(CmuxStatus.accessDenied.hint)
    // Connected/absent states say nothing — no banner noise.
    XCTAssertNil(CmuxStatus.connected(workspaces: 2).hint)
    XCTAssertNil(CmuxStatus.notInstalled.hint)
  }

  /// The socket password must never reach argv: `ps` is world-readable on
  /// macOS, so `--password <secret>` would hand the user's cmux password to
  /// every local process — including the ones Pier lists.
  func testPasswordNeverAppearsInArguments() {
    let arguments = CmuxAccess.arguments()
    XCTAssertEqual(arguments.first, "top")
    XCTAssertFalse(arguments.contains("--password"))
    XCTAssertFalse(arguments.contains { $0.contains("s3cret") })

    XCTAssertEqual(
      CmuxAccess.environment(password: "s3cret"),
      [CmuxAccess.passwordEnvironmentKey: "s3cret"])
    XCTAssertTrue(CmuxAccess.environment(password: nil).isEmpty)
    XCTAssertTrue(CmuxAccess.environment(password: "").isEmpty)
  }

  func testReadsSocketSettingsFromJSONWithComments() {
    // cmux.json allows comments, which JSONSerialization rejects outright.
    let text = """
      {
        // socket
        "socketControlMode": "cmuxOnly",
        "socketPassword": "hunter2",
      }
      """
    let parsed = CmuxAccess.parseConfig(text)
    XCTAssertEqual(parsed.mode, "cmuxOnly")
    XCTAssertEqual(parsed.password, "hunter2")
  }
}

/// The bug this guards: cmux ships its config with a large commented-out
/// example block that contains `"socketControlMode": "allowAll"`. Matching the
/// raw file found that example, concluded the socket was already open, and had
/// Pier tell the user to restart cmux — after which nothing changed, because
/// the real setting had never been set.
final class CmuxConfigCommentTests: XCTestCase {
  private let realShape = """
    {
      "appearance" : { "sidebarTintHex" : "#101014" },

    //   "automation" : {
    //     "socketControlMode" : "allowAll",
    //     "socketPassword" : "EXAMPLE-NOT-A-REAL-PASSWORD",
    //     "portBase" : 9100
    //   },

      "openMarkdownInCmuxViewer" : true
    }
    """

  func testCommentedExampleIsNotTreatedAsConfiguration() {
    let parsed = CmuxAccess.parseConfig(realShape)
    XCTAssertNil(parsed.mode, "a commented example must not count as configured")
    XCTAssertNil(parsed.password, "must not pick a password out of a comment")
  }

  func testRealSettingIsStillFound() {
    let configured = """
      {
        "automation" : {
          "socketControlMode" : "allowAll",
          "socketPassword" : "s3cret"
        }
      }
      """
    let parsed = CmuxAccess.parseConfig(configured)
    XCTAssertEqual(parsed.mode, "allowAll")
    XCTAssertEqual(parsed.password, "s3cret")
  }

  /// A real setting alongside the commented example — the live one wins.
  func testLiveSettingBeatsACommentedOne() {
    let mixed = """
      {
      //   "socketControlMode" : "allowAll",
        "automation" : { "socketControlMode" : "cmuxOnly" }
      }
      """
    XCTAssertEqual(CmuxAccess.parseConfig(mixed).mode, "cmuxOnly")
  }

  func testSlashesInsideStringsSurvive() {
    let withURL = """
      {
        "docsURL" : "https://example.com/guide//x",
        "automation" : { "socketControlMode" : "allowAll" }
      }
      """
    let stripped = CmuxAccess.stripComments(withURL)
    XCTAssertTrue(stripped.contains("https://example.com/guide//x"), "URL must not be truncated")
    XCTAssertEqual(CmuxAccess.parseConfig(withURL).mode, "allowAll")
  }

  /// With nothing configured, the advice must be the "set it" variant — not the
  /// "restart cmux" one that sent the user chasing a restart.
  func testUnconfiguredGivesTheSetItAdvice() {
    let mode = CmuxAccess.parseConfig(realShape).mode
    let detail = CmuxAccess.deniedDetail(configuredMode: mode)
    XCTAssertTrue(detail.contains("socketControlMode"))
    XCTAssertFalse(
      CmuxAccess.deniedHint(configuredMode: mode).lowercased().contains("restart"),
      "must not claim a restart is needed when the setting was never set")
  }
}
