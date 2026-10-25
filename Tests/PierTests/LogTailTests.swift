import XCTest

@testable import Pier

final class LogSourceTests: XCTestCase {
  func testContainerRowsGetTheirEngineCommand() {
    let docker = ActivityEntry(kind: .docker, name: "web", detail: "nginx · Up")
    XCTAssertEqual(LogSource.resolve(activity: docker), .docker(container: "web"))
    XCTAssertEqual(
      LogSource.resolve(activity: docker).arguments(),
      ["logs", "--tail", "300", "--follow", "web"])
    XCTAssertTrue(LogSource.resolve(activity: docker).isStream)

    let apple = ActivityEntry(kind: .apple, name: "pier-web", detail: "nginx · running")
    XCTAssertEqual(LogSource.resolve(activity: apple), .appleContainer(container: "pier-web"))
    // Apple's CLI has no --follow, so it's polled as a snapshot.
    XCTAssertFalse(LogSource.resolve(activity: apple).isStream)
    XCTAssertEqual(LogSource.resolve(activity: apple).arguments(), ["logs", "pier-web"])
  }

  /// MCP servers speak stdio to their harness — there is no log to read, and
  /// saying so beats an empty panel.
  func testMCPRowsExplainWhyThereIsNoLog() {
    let mcp = ActivityEntry(kind: .mcp, name: "node · mcp-fs", detail: "cmd", pids: [1])
    let source = LogSource.resolve(activity: mcp)
    XCTAssertFalse(source.isAvailable)
    XCTAssertTrue(source.label.lowercased().contains("stdio"))
    XCTAssertTrue(source.arguments().isEmpty)
  }

  func testCmuxSurfaceIsTheRouteToADevServersOutput() {
    var entry = PortEntry(
      pid: 9122, port: 5173, proto: .tcp, processName: "node", user: "dev",
      bindAddresses: ["127.0.0.1"],
      attribution: .cmux(workspace: "Acme Web", surface: "make dev", harness: nil))
    entry.cmuxSurfaceRef = "surface:19"
    XCTAssertEqual(
      LogSource.resolve(port: entry), .cmuxSurface(ref: "surface:19", title: "make dev"))
    XCTAssertEqual(
      LogSource.resolve(port: entry).arguments(),
      ["read-screen", "--surface", "surface:19", "--scrollback", "--lines", "300"])
    // The password travels in the environment, never in argv (ps is public).
    XCTAssertFalse(LogSource.resolve(port: entry).arguments().contains("--password"))
    XCTAssertEqual(
      LogSource.resolve(port: entry).environment(cmuxPassword: "pw"),
      [CmuxAccess.passwordEnvironmentKey: "pw"])
  }

  func testPlainDevServerSaysWhyItCannotBeTailed() {
    let entry = PortEntry(
      pid: 10352, port: 5182, proto: .tcp, processName: "node", user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .none)
    let source = LogSource.resolve(port: entry)
    XCTAssertFalse(source.isAvailable)
    XCTAssertTrue(
      source.label.contains("cmux"), "should point at the one way to make it readable")
  }

  func testSystemProcessesPointAtConsole() {
    let entry = PortEntry(
      pid: 98, port: 80, proto: .tcp, processName: "httpd", user: "root",
      bindAddresses: ["*"], attribution: .system)
    XCTAssertFalse(LogSource.resolve(port: entry).isAvailable)
    XCTAssertTrue(LogSource.resolve(port: entry).label.contains("Console"))
  }
}

final class LogTextTests: XCTestCase {
  /// A pipe read can end mid-line; the remainder must survive to the next chunk
  /// or long lines get torn in half.
  func testSplitHoldsPartialLines() {
    var (lines, carry) = LogText.split("alpha\nbeta\ngam", carry: "")
    XCTAssertEqual(lines, ["alpha", "beta"])
    XCTAssertEqual(carry, "gam")

    (lines, carry) = LogText.split("ma\ndelta\n", carry: carry)
    XCTAssertEqual(lines, ["gamma", "delta"], "the held fragment completes its line")
    XCTAssertEqual(carry, "")
  }

  func testSplitWithoutNewlineEmitsNothingYet() {
    let (lines, carry) = LogText.split("no newline here", carry: "")
    XCTAssertTrue(lines.isEmpty)
    XCTAssertEqual(carry, "no newline here")
  }

  func testAppendCappedDropsOldestFirst() {
    let existing = (1...5).map(String.init)
    let result = LogText.appendCapped(existing, adding: ["6", "7"], cap: 4)
    XCTAssertEqual(result, ["4", "5", "6", "7"])
  }

  func testAppendCappedLeavesShortListsAlone() {
    XCTAssertEqual(LogText.appendCapped(["a"], adding: ["b"], cap: 10), ["a", "b"])
  }

  /// cmux scrollback is a rendered terminal, so it arrives full of escape codes.
  func testStripsANSIEscapes() {
    XCTAssertEqual(
      LogText.stripANSI("\u{1B}[32mready\u{1B}[0m in 431ms"), "ready in 431ms")
    XCTAssertEqual(LogText.stripANSI("\u{1B}[2K\u{1B}[1G$ npm run dev"), "$ npm run dev")
    XCTAssertEqual(LogText.stripANSI("plain text"), "plain text")
  }
}
