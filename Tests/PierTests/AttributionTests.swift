@testable import Pier
import XCTest

/// Token matching must respect word boundaries. A bare `hasPrefix` reported
/// CodexBar (a usage monitor) as the Codex harness, so its child's ports were
/// grouped as agent sessions — and "cancelling Codex" from Pier did nothing
/// visible, because there was no Codex session there to cancel.
final class HarnessMatchTests: XCTestCase {
  func testCodexBarIsNotTheCodexHarness() {
    XCTAssertFalse(Attributor.matches(name: "codexbar", token: "codex"))
    XCTAssertEqual(Attributor.harnessLabel(for: "CodexBar"), "CodexBar")
    XCTAssertEqual(Attributor.harnessLabel(for: "codex"), "Codex")
  }

  /// `agy` is Antigravity's CLI. CodexBar shells out to it, so without a rule
  /// of its own the row was labeled by its *launcher* rather than by what the
  /// process actually is — and the process is the more specific truth.
  func testAntigravityCLIIsNamedByItsOwnBinary() {
    XCTAssertEqual(Attributor.harnessLabel(for: "agy"), "Antigravity")
    XCTAssertEqual(Attributor.iconName(forHarnessLabel: "Antigravity"), "antigravity")

    // Chain: agy (self) <- CodexBar (launcher). Self wins.
    let table = ProcessTable.parse("69986 2161 agy\n2161 1 CodexBar")
    let entry = PortEntry(
      pid: 69986, port: 58994, proto: .tcp, processName: "agy", user: "shawn",
      bindAddresses: ["127.0.0.1"], attribution: .none)
    XCTAssertEqual(
      Attributor.attribute(entry: entry, table: table, cmux: nil),
      .harness("Antigravity"))
  }

  /// A CodexBar child Pier can't identify still gets named by its launcher
  /// rather than dumped into "Other".
  func testUnknownCodexBarChildFallsBackToTheLauncher() {
    let table = ProcessTable.parse("500 2161 some-helper\n2161 1 CodexBar")
    let entry = PortEntry(
      pid: 500, port: 51000, proto: .tcp, processName: "some-helper", user: "shawn",
      bindAddresses: ["127.0.0.1"], attribution: .none)
    XCTAssertEqual(
      Attributor.attribute(entry: entry, table: table, cmux: nil), .harness("CodexBar"))
  }

  func testBoundaryCharactersStillMatch() {
    // Real ucomm values that must keep matching.
    XCTAssertEqual(Attributor.harnessLabel(for: "claude-code"), "Claude Code")
    XCTAssertEqual(Attributor.harnessLabel(for: "Cursor Helper ("), "Cursor")
    XCTAssertEqual(Attributor.harnessLabel(for: "codex.wrapper"), "Codex")
    XCTAssertEqual(Attributor.harnessLabel(for: "claude_worker"), "Claude Code")
  }

  func testTrailingLettersOrDigitsAreDifferentWords() {
    XCTAssertNil(Attributor.harnessLabel(for: "warpd"))
    XCTAssertNil(Attributor.harnessLabel(for: "zedmon"))
    XCTAssertNil(Attributor.harnessLabel(for: "codex2fa"))
    // "codex" must not fall through to the "code" (VS Code) rule either.
    XCTAssertEqual(Attributor.harnessLabel(for: "codex"), "Codex")
  }
}

final class AttributionTests: XCTestCase {
  /// node (5584) <- bash (5583) <- kimi (94683) <- zsh (1000) <- launchd
  let psFixture = """
    5584  5583 node
    5583 94683 bash
   94683  1000 kimi
    1000     1 zsh
  """

  let cmuxFixture = """
  12.9\t1028612200\t22\tworkspace\tworkspace:4\twindow:1\tPersonal Agent
  9.2\t559616400\t10\tsurface\tsurface:19\tpane:6\tKimi
  4.0\t320515680\t1\tprocess\t94683\tsurface:19\tkimi
  """

  private func entry(pid: Int32 = 5584, port: Int = 3000, user: String = "shawn", name: String = "node") -> PortEntry {
    PortEntry(
      pid: pid, port: port, proto: .tcp, processName: name, user: user,
      bindAddresses: ["127.0.0.1"], attribution: .none
    )
  }

  func testProcessTableChain() {
    let table = ProcessTable.parse(psFixture)
    XCTAssertEqual(table.chain(from: 5584).map(\.pid), [5584, 5583, 94683, 1000])
    XCTAssertTrue(table.chain(from: 424242).isEmpty)
  }

  func testCmuxAttributionViaAncestorWalk() {
    let table = ProcessTable.parse(psFixture)
    let cmux = CmuxSnapshot.parse(cmuxFixture)
    let attribution = Attributor.attribute(entry: entry(), table: table, cmux: cmux)
    XCTAssertEqual(
      attribution,
      .cmux(workspace: "Personal Agent", surface: "Kimi", harness: "Kimi")
    )
    // Harness label matches the surface title, so it is not duplicated.
    XCTAssertEqual(attribution.badgeLabel, "cmux · Personal Agent · Kimi")
    XCTAssertEqual(attribution.groupTitle, "cmux · Personal Agent")
  }

  func testCmuxAttributionWithDifferentHarnessAppended() {
    let table = ProcessTable.parse(psFixture)
    let cmux = CmuxSnapshot.parse("""
      1.0\t100\t1\tworkspace\tworkspace:1\twindow:1\tBackend
      1.0\t100\t1\tsurface\tsurface:2\tpane:1\tserver
      1.0\t100\t1\tprocess\t94683\tsurface:2\tzsh
      """)
    let attribution = Attributor.attribute(entry: entry(), table: table, cmux: cmux)
    XCTAssertEqual(attribution.badgeLabel, "cmux · Backend · server · Kimi")
  }

  func testHarnessOnlyWithoutCmux() {
    let table = ProcessTable.parse(psFixture)
    let attribution = Attributor.attribute(entry: entry(), table: table, cmux: nil)
    XCTAssertEqual(attribution, .harness("Kimi"))
  }

  func testClaudeDetectedByProcessNamePrefix() {
    XCTAssertEqual(Attributor.harnessLabel(for: "claude"), "Claude Code")
    XCTAssertEqual(Attributor.harnessLabel(for: "Code Helper (Pl"), "VS Code")
    XCTAssertEqual(Attributor.harnessLabel(for: "Cursor Helper ("), "Cursor")
    XCTAssertEqual(Attributor.harnessLabel(for: "iTerm2"), "iTerm")
    XCTAssertNil(Attributor.harnessLabel(for: "python3"))
  }

  func testSystemAttribution() {
    let table = ProcessTable.parse(psFixture)
    let cmux = CmuxSnapshot.parse(cmuxFixture)
    // Root-owned process.
    XCTAssertEqual(
      Attributor.attribute(entry: entry(user: "root"), table: table, cmux: cmux),
      .system
    )
    // Privileged port even for a non-root user.
    XCTAssertEqual(
      Attributor.attribute(entry: entry(port: 443), table: table, cmux: cmux),
      .system
    )
  }

  func testUnattributedDevServer() {
    let table = ProcessTable.parse(psFixture)
    let attribution = Attributor.attribute(entry: entry(pid: 77777, name: "python3"), table: table, cmux: nil)
    XCTAssertEqual(attribution, .none)
    XCTAssertEqual(attribution.badgeLabel, "local")
  }

  func testGroupOrdering() {
    var unattributed = entry(pid: 1, port: 8080)
    unattributed.attribution = .none
    var system = entry(pid: 2, port: 53, user: "root")
    system.attribution = .system
    var attributed = entry(pid: 3, port: 3000)
    attributed.attribution = .cmux(workspace: "W", surface: "S", harness: nil)

    let entries = [unattributed, system, attributed]
    var byTitle: [String: (rank: Int, entries: [PortEntry])] = [:]
    for e in entries {
      var bucket = byTitle[e.attribution.groupTitle] ?? (e.attribution.groupRank, [])
      bucket.entries.append(e)
      byTitle[e.attribution.groupTitle] = bucket
    }
    let titles = byTitle
      .sorted { $0.value.rank != $1.value.rank ? $0.value.rank < $1.value.rank : $0.key < $1.key }
      .map(\.key)
    XCTAssertEqual(titles, ["cmux · W", "Other", "System"])
  }
}

/// Apple's own services run as the logged-in user on unprivileged ports —
/// ControlCenter's AirPlay Receiver on :5000 looks exactly like a Flask app by
/// user and port, and it outranked real dev servers once activity sorting
/// landed. The executable path settles it without naming vendors.
final class SystemBinaryTests: XCTestCase {
  func testRecognizesAppleShippedPaths() {
    let system = [
      "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
      "/usr/libexec/rapportd",
      "/usr/sbin/cupsd",
      "/Library/Apple/System/Library/somebinary",
    ]
    for path in system {
      XCTAssertTrue(Attributor.isSystemBinary(path), "expected system: \(path)")
    }
  }

  func testUserBinariesAreNotSystem() {
    let mine = [
      "/opt/homebrew/bin/node /Users/shawn/code/app/server.js",
      "/Users/shawn/.nvm/versions/node/v24.16.0/bin/node",
      "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser",
      "/usr/local/bin/container",
      // /usr/bin is user-invocable (python3, ruby) — a script there may well be
      // yours, so it must NOT be swept into System.
      "/usr/bin/python3 -m http.server 8899",
    ]
    for path in mine {
      XCTAssertFalse(Attributor.isSystemBinary(path), "expected not system: \(path)")
    }
  }
}
