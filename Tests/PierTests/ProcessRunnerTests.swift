import XCTest

@testable import Pier

/// ProcessRunner must return on time whatever its child leaves behind. Uses
/// /bin/sh — always present — because the failure is about real pipes and
/// real orphans, which a captured fixture can't reproduce.
final class ProcessRunnerTests: XCTestCase {
  /// The hang: a CLI that starts a background helper passes its stdout down,
  /// so the pipe never reaches EOF after the CLI itself exits. This used to
  /// block for as long as the helper lived (30 s here; forever for a daemon).
  func testReturnsWhenAnOrphanHoldsThePipe() throws {
    let started = Date()
    let result = try XCTUnwrap(
      ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & echo hello"], timeout: 10))
    XCTAssertLessThan(Date().timeIntervalSince(started), 3, "must not wait on the orphan")
    XCTAssertEqual(result.stdout, "hello\n")
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.timedOut)
  }

  /// The child itself hangs: killed at the timeout, output so far kept.
  func testTimeoutKillsAndReturns() throws {
    let started = Date()
    let result = try XCTUnwrap(
      ProcessRunner.run("/bin/sh", ["-c", "echo partial; exec sleep 30"], timeout: 1))
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertGreaterThanOrEqual(elapsed, 0.9)
    XCTAssertLessThan(elapsed, 3)
    XCTAssertTrue(result.timedOut)
    XCTAssertEqual(result.stdout, "partial\n")
  }

  /// Both pipes drain together: a child that fills stderr past the 64 KB pipe
  /// buffer before writing stdout must not deadlock.
  func testLargeStderrAndStdoutBothArrive() throws {
    let result = try XCTUnwrap(
      ProcessRunner.run(
        "/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\\\0' x >&2; echo done"],
        timeout: 10))
    XCTAssertEqual(result.stderr.count, 200_000)
    XCTAssertEqual(result.stdout, "done\n")
  }
}
