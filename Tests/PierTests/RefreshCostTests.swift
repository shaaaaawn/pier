import XCTest

@testable import Pier

/// Locks in the three per-refresh cost cuts. Each one is a pure rewrite of
/// work that was already being done, so the bar for all of them is "same
/// answer, less work" — these tests pin the "same answer" half.
final class RefreshCostTests: XCTestCase {
  // MARK: - One lsof call for both protocols

  /// Shaped like `lsof +c 0 -nP -iTCP -sTCP:LISTEN -iUDP`: protocols interleave,
  /// because lsof orders by process, not by the -i flag that matched.
  let combined = """
    COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    mDNSRespo   123 _mdnsresponder 6u IPv4 0x1      0t0  UDP *:5353
    node      90220 dev   22u  IPv6 0x111         0t0  TCP [::1]:3000 (LISTEN)
    node      90220 dev   23u  IPv4 0x222         0t0  TCP 127.0.0.1:3000 (LISTEN)
    node      90220 dev   30u  IPv4 0x2           0t0  UDP 192.168.1.5:53122->8.8.8.8:53
    node      90220 dev   31u  IPv4 0x3           0t0  UDP *:5173
    python3   73101 dev    3u  IPv4 0xdef456      0t0  TCP *:8931 (LISTEN)
    """

  func testProtocolIsReadPerRowFromTheNodeColumn() {
    let records = LsofParser.parse(combined)
    XCTAssertEqual(records.filter { $0.proto == .udp }.map(\.port).sorted(), [5173, 5353])
    XCTAssertEqual(records.filter { $0.proto == .tcp }.map(\.port).sorted(), [3000, 3000, 8931])
  }

  /// A connected UDP socket is a client, not a listener — still excluded.
  func testConnectedUDPIsStillExcluded() {
    XCTAssertFalse(LsofParser.parse(combined).contains { $0.port == 53122 })
  }

  func testIPv6RowsSurviveTheMerge() {
    let node = PortMonitor.buildEntries(sockets: combined).first {
      $0.port == 3000 && $0.proto == .tcp
    }
    XCTAssertEqual(Set(node?.bindAddresses ?? []), ["::1", "127.0.0.1"])
  }

  /// TCP 3000 and UDP 3000 on one pid are different sockets, not duplicates.
  func testSamePortDifferentProtocolStaysTwoEntries() {
    let both = """
      COMMAND  PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
      thing    500 dev 4u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)
      thing    500 dev 5u IPv4 0x2 0t0 UDP 127.0.0.1:3000
      """
    let entries = PortMonitor.buildEntries(sockets: both)
    XCTAssertEqual(Set(entries.map(\.proto)), [.tcp, .udp])
  }

  /// The row's own NODE column beats the caller's hint, so a mislabelled
  /// single-protocol capture can't flip a socket's protocol.
  func testNodeColumnWinsOverTheFallbackHint() {
    let records = LsofParser.parse(combined, proto: .tcp)
    XCTAssertEqual(records.first { $0.port == 5353 }?.proto, .udp)
  }

  /// The combined call interleaves TCP and UDP, so entry order changes. Nothing
  /// downstream may depend on it: groups must be identical for any input order.
  func testGroupsDoNotDependOnLsofRowOrder() {
    let header = combined.split(separator: "\n").first.map(String.init) ?? ""
    let rows = combined.split(separator: "\n").dropFirst().map(String.init)
    let forward = PortMonitor.buildEntries(sockets: combined)
    for seed in 0..<8 {
      var generator = SplitMix(seed: UInt64(seed))
      let shuffled = ([header] + rows.shuffled(using: &generator)).joined(separator: "\n")
      let groups = PortMonitor.buildGroups(
        entries: PortMonitor.buildEntries(sockets: shuffled), matching: "", sort: .activity,
        history: UsageHistory())
      let baseline = PortMonitor.buildGroups(
        entries: forward, matching: "", sort: .activity, history: UsageHistory())
      XCTAssertEqual(
        groups.map { $0.rows.map(\.id) }, baseline.map { $0.rows.map(\.id) },
        "group/row order changed for shuffle seed \(seed)")
    }
  }

  // MARK: - MCP prefilter

  /// The prefilter must never reject a line the full check would accept. These
  /// are the shapes the full check accepts, including the needle that does not
  /// contain "mcp" and an upper-case one that only `lowercased()` would catch.
  func testPrefilterPassesEverythingTheFullCheckAccepts() {
    let accepted = [
      "4100 dev node /Users/you/.npm/_npx/x/chrome-devtools-mcp/build/index.js",
      "4101 dev npx @modelcontextprotocol/server-github",
      "4102 dev /usr/local/bin/MCP-Proxy --stdio",
      "4103 dev uvx Blender-MCP",
    ]
    for line in accepted {
      let command = line.split(separator: " ").dropFirst(2).joined(separator: " ")
      XCTAssertTrue(
        ActivityParser.isMCPCommand(command.lowercased()), "fixture should be MCP: \(line)")
      XCTAssertTrue(ActivityParser.mightMentionMCP(Substring(line)), "prefilter dropped: \(line)")
    }
  }

  func testPrefilterRejectsLinesWithNoNeedle() {
    for line in ["1 root /sbin/launchd", "90220 dev node vite.js --port 5173", "77 dev mc ps"] {
      XCTAssertFalse(ActivityParser.mightMentionMCP(Substring(line)), line)
    }
  }

  /// Non-ASCII bytes (UTF-8 multibyte) can never be folded onto an ASCII letter.
  func testPrefilterIgnoresNonASCIIBytes() {
    XCTAssertFalse(ActivityParser.mightMentionMCP("5 dev ｍｃｐ-server"))  // fullwidth
    XCTAssertTrue(ActivityParser.mightMentionMCP("5 dev café-mcp"))
  }

  /// Property check over every prefix-split of a long mixed line: wherever the
  /// full check accepts, the prefilter accepts.
  func testPrefilterIsASupersetOfTheFullCheck() {
    let words = [
      "node", "MCP", "server", "@ModelContextProtocol/x", "grep", "mcp", "-v", "cat", "tool",
    ]
    var generator = SplitMix(seed: 42)
    for _ in 0..<500 {
      let command = (0..<4).map { _ in words.randomElement(using: &generator)! }.joined(
        separator: " ")
      let line = "123 dev \(command)"
      if ActivityParser.isMCPCommand(command.lowercased()) {
        XCTAssertTrue(ActivityParser.mightMentionMCP(Substring(line)), line)
      }
    }
  }

  // MARK: - Command-line parsing without split-and-join

  /// The old implementation, kept here as the oracle the fast path must match.
  private func oracle(_ line: Substring) -> (Int32, String)? {
    let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard tokens.count >= 3, let pid = Int32(tokens[0]) else { return nil }
    return (pid, tokens.dropFirst(2).joined(separator: " "))
  }

  func testCommandLineMatchesTheOldSplitAndJoin() {
    let lines: [Substring] = [
      "  4100 dev node /a/b.js --port 5173",
      "4100 dev node  /a/b.js",  // doubled space inside the command
      "4100 dev\tnode\t/a/b.js",  // tabs
      "4100 dev node /a/b.js   ",  // trailing spaces
      "4100   dev    node",  // runs between columns
      "4100 dev",  // no command
      "abc dev node",  // non-numeric pid
      "",
      "   ",
      "-1 root weird",
    ]
    for line in lines {
      let new = PortMonitor.commandLine(line)
      let old = oracle(line)
      XCTAssertEqual(new?.0, old?.0, "pid for \"\(line)\"")
      XCTAssertEqual(new?.1, old?.1, "command for \"\(line)\"")
    }
  }

  func testFirstTokenMatchesSplitFirst() {
    for text in ["/usr/libexec/rapportd -x", "  leading", "solo", "", "   ", "a  b"] {
      let expected = text.split(separator: " ").first.map(String.init) ?? ""
      XCTAssertEqual(String(Attributor.firstToken(text)), expected, "\"\(text)\"")
    }
    XCTAssertTrue(Attributor.isSystemBinary("  /usr/libexec/rapportd -x"))
    XCTAssertFalse(Attributor.isSystemBinary("/usr/bin/python3 -m http.server"))
  }

  // MARK: - Attribution cache

  func testCacheReturnsWhatTheDirectCallReturns() {
    let commands: [Int32: String] = [
      10: "/opt/homebrew/bin/claude", 11: "node /Users/you/app/vite.js", 12: "",
    ]
    let cache = CommandLabelCache(commands)
    for pid: Int32 in [10, 11, 12, 99] {
      let direct = commands[pid].flatMap { Attributor.harnessLabel(fromCommand: $0) }
      XCTAssertEqual(cache.label(for: pid), direct, "pid \(pid)")
      XCTAssertEqual(cache.label(for: pid), direct, "pid \(pid), cached")
    }
  }
}

/// Deterministic shuffles, so a failure names a reproducible seed.
struct SplitMix: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
