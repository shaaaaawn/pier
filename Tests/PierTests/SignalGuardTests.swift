import XCTest

@testable import Pier

/// `kill()` treats non-positive pids as groups: 0 is our own process group and
/// -1 is every process this user owns. A bad parse reaching `kill(-1, SIGKILL)`
/// would take down every app on the desktop, so the guard is the whole point.
final class SignalGuardTests: XCTestCase {
  func testRefusesSpecialPids() {
    XCTAssertFalse(PortMonitor.isSignalable(0), "0 is our own process group")
    XCTAssertFalse(PortMonitor.isSignalable(-1), "-1 is every process the user owns")
    XCTAssertFalse(PortMonitor.isSignalable(-4242), "negative is a process group")
    XCTAssertFalse(PortMonitor.isSignalable(1), "1 is launchd")
  }

  func testAllowsOrdinaryPids() {
    XCTAssertTrue(PortMonitor.isSignalable(2))
    XCTAssertTrue(PortMonitor.isSignalable(51_731))
  }

  /// `Int32(String)` accepts "-1" and "0", so the parsers can't be relied on to
  /// keep these out — which is why the guard sits at the signal, not the parse.
  func testTheParserReallyDoesAcceptThem() {
    XCTAssertEqual(Int32("-1"), -1)
    XCTAssertEqual(Int32("0"), 0)
  }
}
