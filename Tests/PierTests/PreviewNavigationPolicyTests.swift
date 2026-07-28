import Foundation
import XCTest

@testable import Pier

/// The previewed page is untrusted — it's whatever is listening on a port. Left
/// unrestricted, one redirect turns Pier into an outbound HTTP client for an
/// arbitrary host, which contradicts the posture the README states.
final class PreviewNavigationPolicyTests: XCTestCase {
  private func url(_ s: String) -> URL { URL(string: s)! }

  func testAllowsTheHostPierAskedFor() {
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(url("http://127.0.0.1:5173/app"), expectedHost: "127.0.0.1"))
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(url("http://192.168.1.5:3000/"), expectedHost: "192.168.1.5"))
  }

  /// A port bound to a LAN address previews on that address, so loopback alone
  /// would be too narrow — but loopback is always the local machine.
  func testAlwaysAllowsLoopbackRegardlessOfExpectedHost() {
    for host in ["127.0.0.1", "localhost", "[::1]"] {
      XCTAssertTrue(
        PreviewNavigationPolicy.allows(url("http://\(host):8080/"), expectedHost: "192.168.1.5"),
        "expected loopback host \(host) to be allowed")
    }
  }

  /// The headline case: the page redirects itself somewhere external.
  func testBlocksNavigationToAnotherHost() {
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(
        url("https://attacker.example/collect"), expectedHost: "127.0.0.1"))
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(url("http://evil.test/"), expectedHost: "127.0.0.1"))
  }

  /// Anything that isn't http(s) is a way out of the sandbox we just built.
  func testBlocksNonWebSchemes() {
    for bad in [
      "file:///etc/passwd",
      "data:text/html,<script>alert(1)</script>",
      "javascript:alert(1)",
      "ftp://example.com/",
      "pier://whatever",
    ] {
      XCTAssertFalse(
        PreviewNavigationPolicy.allows(url(bad), expectedHost: "127.0.0.1"),
        "expected \(bad) to be blocked")
    }
  }

  /// WKWebView navigates here internally; blocking it breaks ordinary loads.
  func testAllowsAboutBlank() {
    XCTAssertTrue(PreviewNavigationPolicy.allows(url("about:blank"), expectedHost: "127.0.0.1"))
  }

  func testBlocksWhenNoExpectedHostIsKnown() {
    XCTAssertFalse(PreviewNavigationPolicy.allows(url("http://example.com/"), expectedHost: nil))
    XCTAssertTrue(PreviewNavigationPolicy.allows(url("http://127.0.0.1/"), expectedHost: nil))
  }

  /// Host comparison must not be case-sensitive, or `LOCALHOST` slips through
  /// the loopback check and `EXAMPLE.com` fails the same-host check.
  func testHostMatchingIsCaseInsensitive() {
    XCTAssertTrue(PreviewNavigationPolicy.allows(url("http://LOCALHOST:3000/"), expectedHost: nil))
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(url("http://EXAMPLE.com/"), expectedHost: "example.com"))
  }
}
