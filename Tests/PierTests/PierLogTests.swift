import Foundation
import XCTest

@testable import Pier

final class PierLogTests: XCTestCase {
  func testFormatPrefixesTimestampAndEndsWithNewline() {
    let line = PierLog.format("docker start", at: Date(timeIntervalSince1970: 0))
    XCTAssertTrue(line.hasSuffix("docker start\n"))
    // Local time, so the date depends on the machine's zone — assert the
    // ISO-8601 shape rather than a fixed instant.
    let stamp = String(line.prefix(while: { $0 != " " }))
    XCTAssertNotNil(
      ISO8601DateFormatter().date(from: stamp), "expected an ISO timestamp, got \(stamp)")
  }

  func testRotatesOnlyAtTheLimit() {
    XCTAssertFalse(PierLog.shouldRotate(size: 99, limit: 100))
    XCTAssertTrue(PierLog.shouldRotate(size: 100, limit: 100))
    XCTAssertTrue(PierLog.shouldRotate(size: 101, limit: 100))
  }

  /// The log must never carry a credential even if a caller slips and logs
  /// something argv-shaped.
  func testRedactsCredentialAssignments() {
    XCTAssertEqual(
      PierLog.redact("env CMUX_SOCKET_PASSWORD=hunter2 cmux"),
      "env CMUX_SOCKET_PASSWORD=*** cmux")
    XCTAssertEqual(
      PierLog.redact("run --api-key=sk-abc123 --port=8080"),
      "run --api-key=*** --port=8080")
    XCTAssertEqual(
      PierLog.redact("GITHUB_TOKEN=ghp_xyz next"), "GITHUB_TOKEN=*** next")
    // Separator-insensitive: the hyphen form is what slipped through first.
    XCTAssertEqual(PierLog.redact("apiKey=abc"), "apiKey=***")
    XCTAssertEqual(PierLog.redact("Authorization=Bearer xyz"), "Authorization=*** xyz")
  }

  func testLeavesOrdinaryAssignmentsAlone() {
    XCTAssertEqual(PierLog.redact("docker prune --filter=until=24h"),
      "docker prune --filter=until=24h")
    XCTAssertEqual(PierLog.redact("stop data_redis: exit 0"), "stop data_redis: exit 0")
  }

  /// Tool output is the one thing that reaches the log without a caller
  /// choosing every word, so it is bounded as well as redacted.
  func testSummarizeBoundsToolOutput() {
    XCTAssertEqual(PierLog.summarize(""), "(no output)")
    XCTAssertEqual(PierLog.summarize("   \n\n"), "(no output)")
    XCTAssertEqual(
      PierLog.summarize("Error: No such container: nope\nEnsure the daemon…"),
      "Error: No such container: nope",
      "only the first line — a multi-line engine error must not dump onto disk")
    let long = String(repeating: "x", count: 500)
    let out = PierLog.summarize(long)
    XCTAssertEqual(out.count, 201, "200 chars plus the ellipsis")
    XCTAssertTrue(out.hasSuffix("…"))
  }

  func testLogsGoToTheDocumentedLocation() {
    XCTAssertTrue(
      PierLog.fileURL.path.hasSuffix("Library/Logs/Pier/pier.log"),
      "README and CLAUDE.md both point at ~/Library/Logs/Pier/pier.log — got \(PierLog.fileURL.path)"
    )
  }
}
