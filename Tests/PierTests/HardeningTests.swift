import XCTest

@testable import Pier

/// Fixes from the 2026-10 security / performance review: each test pins the
/// failure it closes. (ProcessRunner's hang has its own suite.)
final class HardeningTests: XCTestCase {
  // MARK: - Log forging via process names

  /// A process can put a newline in its own name; lsof escapes it as \x0a.
  /// Decoded verbatim it split a Pier log line and forged a new entry.
  func testControlBytesInProcessNamesAreNeutralised() {
    XCTAssertEqual(LsofParser.unescape(#"evil\x0a2026 you stopped x"#), "evil?2026 you stopped x")
    XCTAssertEqual(LsofParser.unescape(#"a\x0db\x7fc\x09d"#), "a?b?c?d")
    XCTAssertEqual(
      LsofParser.unescape(#"Cursor\x20Helper"#), "Cursor Helper", "space still decodes")
  }

  func testLogMessagesStayOnOneLine() {
    XCTAssertEqual(
      PierLog.singleLine("started evil\nforged line\r\nmore"), "started evil forged line more")
    XCTAssertFalse(PierLog.format(PierLog.singleLine("a\nb"), at: Date()).dropLast().contains("\n"))
  }

  // MARK: - Killing a recycled pid

  func testKillRefusesAPidThatChangedHands() {
    XCTAssertTrue(PortMonitor.isSameProcess(expected: 100, current: 100))
    XCTAssertFalse(PortMonitor.isSameProcess(expected: 100, current: 250), "recycled pid")
    XCTAssertFalse(PortMonitor.isSameProcess(expected: 100, current: nil), "process gone")
    XCTAssertTrue(PortMonitor.isSameProcess(expected: nil, current: 250), "no record: probes")
  }

  /// libproc's start time is stable for a process and readable for our own.
  func testStartTimeIsStableForALiveProcess() throws {
    let first = try XCTUnwrap(PortMonitor.startTime(of: getpid()))
    XCTAssertEqual(PortMonitor.startTime(of: getpid()), first)
    XCTAssertLessThan(first, UInt64(Date().timeIntervalSince1970 * 1_000_000))
  }

  // MARK: - Unbounded log memory

  /// A stream that never sends a newline used to grow the carry forever.
  func testNewlineFreeStreamIsCapped() {
    let huge = String(repeating: "x", count: LogText.maxCarry + 10)
    let (lines, carry) = LogText.split(huge, carry: "")
    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(lines[0].utf8.count, LogText.maxCarry)
    XCTAssertEqual(carry, "")
    // Ordinary partial lines are still held for their newline.
    XCTAssertEqual(LogText.split("abc", carry: "").carry, "abc")
    XCTAssertEqual(LogText.split("de\nf", carry: "abc").lines, ["abcde"])
  }

  // MARK: - Secrets on screen

  func testMCPCommandLinesAreMaskedForDisplay() {
    let ps = "4242 dev node /x/mcp-server/index.js --api-key=sk-live-123 --port 9\n"
    let table = ProcessTable.parse("4242 1 node")
    let rows = ActivityParser.mcpEntries(fullPS: ps, table: table, cmux: nil)
    XCTAssertEqual(rows.count, 1)
    XCTAssertFalse(rows[0].detail.contains("sk-live-123"))
    XCTAssertTrue(rows[0].detail.contains("mcp-server"), "the rest of the command stays readable")
  }
}
