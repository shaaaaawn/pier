import XCTest

@testable import Pier

/// Ports started in Ghostty / Terminal tabs. Process trees are verbatim from
/// this machine: `ghostty -e` runs the command straight under `login`, while a
/// Terminal tab runs a shell under `login` and the server under that.
final class TerminalSessionsTests: XCTestCase {
  let tree = """
    98159     1 0.0 1000 ghostty
    98167 98159 0.0 1000 login
    98169 98167 0.1 9000 Python
    98157     1 0.0 1000 Terminal
    98171 98157 0.0 1000 login
    98172 98171 0.0 2000 zsh
    98817 98172 0.1 9000 python3.11
    98820 98172 0.0 2000 claude
    98821 98820 0.0 9000 node
    """

  let info: [Int32: TerminalSessionInfo] = [
    98169: TerminalSessionInfo(tty: "ttys005", directory: "/private/tmp"),
    // Attribution abbreviates against the real home directory.
    98172: TerminalSessionInfo(tty: "ttys007", directory: NSHomeDirectory() + "/code/web"),
  ]

  func entry(pid: Int32, port: Int, name: String) -> PortEntry {
    PortEntry(
      pid: pid, port: port, proto: .tcp, processName: name, user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .none)
  }

  func attribute(_ e: PortEntry, info: [Int32: TerminalSessionInfo]? = nil) -> Attribution {
    let lookup = info ?? self.info
    return Attributor.attribute(
      entry: e, table: ProcessTable.parse(tree), cmux: nil, labels: CommandLabelCache([:]),
      terminalInfo: { lookup[$0] })
  }

  // MARK: - Session leader

  func testLeaderIsTheChildOfLogin() {
    let table = ProcessTable.parse(tree)
    XCTAssertEqual(TerminalSessions.leader(in: table.chain(from: 98169))?.pid, 98169)
    XCTAssertEqual(TerminalSessions.leader(in: table.chain(from: 98169))?.app, .ghostty)
    XCTAssertEqual(TerminalSessions.leader(in: table.chain(from: 98817))?.pid, 98172)
    XCTAssertEqual(TerminalSessions.leader(in: table.chain(from: 98817))?.app, .terminal)
  }

  func testTerminalAppMatchIsExact() {
    XCTAssertEqual(TerminalApp(processName: "Terminal"), .terminal)
    XCTAssertEqual(TerminalApp(processName: "ghostty"), .ghostty)
    XCTAssertNil(TerminalApp(processName: "terminal-notifier"))
    XCTAssertNil(TerminalApp(processName: "iTerm2"))
  }

  // MARK: - Attribution

  func testGhosttyAndTerminalPortsGroupByTab() {
    let ghostty = attribute(entry(pid: 98169, port: 8978, name: "Python"))
    XCTAssertEqual(ghostty.groupTitle, "Ghostty · /private/tmp")
    let terminal = attribute(entry(pid: 98817, port: 8979, name: "python3.11"))
    XCTAssertEqual(terminal.groupTitle, "Terminal · ~/code/web")
    guard case .terminal(let session) = terminal else { return XCTFail("\(terminal)") }
    XCTAssertEqual(session.tty, "ttys007")
    XCTAssertEqual(terminal.rowBadge(inGroup: terminal.groupTitle), nil)
  }

  /// An agent nearer the port than the terminal keeps the port: Claude Code
  /// run in a Terminal tab is still Claude Code's.
  func testAgentInsideATerminalStaysTheAgent() {
    XCTAssertEqual(attribute(entry(pid: 98821, port: 3000, name: "node")), .harness("Claude Code"))
  }

  /// No libproc answer → exactly the old behaviour.
  func testWithoutSessionInfoTheTerminalLabelStands() {
    XCTAssertEqual(
      attribute(entry(pid: 98169, port: 8978, name: "Python"), info: [:]), .harness("Ghostty"))
  }

  // MARK: - Paths

  func testDisplayPath() {
    let home = "/Users/you"
    XCTAssertEqual(TerminalSessions.displayPath("/Users/you", home: home), "~")
    XCTAssertEqual(TerminalSessions.displayPath("/Users/you/code/web", home: home), "~/code/web")
    XCTAssertEqual(
      TerminalSessions.displayPath("/Users/you/code/acme/apps/web", home: home), "…/apps/web")
    XCTAssertEqual(TerminalSessions.displayPath("/private/tmp", home: home), "/private/tmp")
    // A sibling whose name merely starts with the home path is not under it.
    XCTAssertEqual(TerminalSessions.displayPath("/Users/youth/x", home: home), "/Users/youth/x")
  }

  /// The live reader agrees with `ps` about this test process's own tty and
  /// directory — the only process a test can rely on existing.
  func testLibprocReadsOwnProcess() throws {
    let info = try XCTUnwrap(TerminalSessions.read(pid: getpid()))
    XCTAssertEqual(info.directory, FileManager.default.currentDirectoryPath)
    let ps = ProcessRunner.run("/bin/ps", ["-o", "tty=", "-p", "\(getpid())"], timeout: 5)
    let expected = ps?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    XCTAssertEqual(info.tty ?? "??", expected)
  }

  // MARK: - Logs

  func testTerminalTabsHaveLogsAndGhosttySaysWhyNot() {
    let terminal = entry(pid: 98817, port: 8979, name: "python3.11")
    var withAttribution = terminal
    withAttribution.attribution = attribute(terminal)
    XCTAssertEqual(
      LogSource.resolve(port: withAttribution), .terminalTab(tty: "ttys007", title: "~/code/web"))

    var ghostty = entry(pid: 98169, port: 8978, name: "Python")
    ghostty.attribution = attribute(ghostty)
    guard case .unavailable(let reason) = LogSource.resolve(port: ghostty) else {
      return XCTFail("Ghostty has no readable output")
    }
    XCTAssertTrue(reason.contains("Ghostty"))
  }

  /// The tty is an argument, never part of the script text.
  func testHistoryScriptTakesTheTtyAsAnArgument() {
    let args = TerminalSessions.historyArguments(tty: "ttys007")
    XCTAssertEqual(args.last, "ttys007")
    XCTAssertFalse(args.dropLast().contains { $0.contains("ttys007") })
    XCTAssertEqual(args.filter { $0 == "-e" }.count, TerminalSessions.historyScript.count)
  }

  func testAutomationDenialIsExplained() {
    let denied =
      "execution error: Not authorized to send Apple events to Terminal. (-1743)"
    XCTAssertTrue(
      TerminalSessions.historyFailureReason(denied)?.contains("Automation") ?? false)
    XCTAssertNil(TerminalSessions.historyFailureReason("syntax error"))
  }
}
