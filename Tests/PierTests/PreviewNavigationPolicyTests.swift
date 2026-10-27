import Foundation
import XCTest

@testable import Pier

/// The previewed page is untrusted — it's whatever is listening on a port. Left
/// unrestricted, one redirect turns Pier into an outbound HTTP client for an
/// arbitrary host, which contradicts the posture the README states. And on
/// loopback, "any local port" would turn it into a request forger against every
/// other dev tool on the machine, so loopback is pinned to the port too.
final class PreviewNavigationPolicyTests: XCTestCase {
  private func url(_ s: String) -> URL { URL(string: s)! }

  func testAllowsTheURLPierAskedFor() {
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(
        url("http://127.0.0.1:5173/app"), expected: url("http://127.0.0.1:5173")))
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(
        url("http://192.168.1.5:3000/"), expected: url("http://192.168.1.5:3000")))
  }

  /// The redirect real dev servers actually make: a loopback *spelling* change
  /// on the same port. All three names are this machine.
  func testAllowsLoopbackRenamesOnTheSamePort() {
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(
        url("http://localhost:5173/"), expected: url("http://127.0.0.1:5173")))
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(
        url("http://127.0.0.1:5173/"), expected: url("http://localhost:5173")))
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(
        url("http://[::1]:5173/"), expected: url("http://127.0.0.1:5173")))
  }

  /// The hole this policy closed: `localhost` names hundreds of unrelated
  /// services, and the previewed page doesn't get to pick a different one.
  /// Same machine, different service — blocked.
  func testBlocksLoopbackOnADifferentPort() {
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(
        url("http://127.0.0.1:2375/containers/json"), expected: url("http://127.0.0.1:5173")))
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(
        url("http://localhost:9000/admin"), expected: url("http://127.0.0.1:5173")))
    // Even when the preview itself was opened on loopback by name.
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(
        url("http://localhost:5174/"), expected: url("http://localhost:5173")))
  }

  /// A loopback redirect from a LAN preview is blocked too: `localhost`
  /// resolves to the *viewer's* machine, a different endpoint than the LAN
  /// address the user clicked, so nothing legitimate is being denied.
  func testBlocksLoopbackWhenPreviewingALANHost() {
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(
        url("http://127.0.0.1:3000/"), expected: url("http://192.168.1.5:3000")))
  }

  /// A port bound to a LAN address previews on that address, and real stacks
  /// shift ports on the same host (http→https, app→assets), so off-loopback the
  /// host is the identity.
  func testAllowsAnyPortOnTheExpectedLANHost() {
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(
        url("https://192.168.1.5:3443/"), expected: url("http://192.168.1.5:3000")))
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(
        url("http://192.168.1.6:3000/"), expected: url("http://192.168.1.5:3000")))
  }

  /// `URL.port` is nil for the scheme's default, so the nil port and the
  /// explicit default must agree — and must not be confused with port 8080.
  func testDefaultPortsAreTheEffectivePorts() {
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(url("http://localhost/"), expected: url("http://localhost:80"))
    )
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(
        url("http://localhost:80/"), expected: url("http://localhost/")))
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(
        url("http://localhost:8080/"), expected: url("http://localhost/")))
  }

  /// The headline case: the page redirects itself somewhere external.
  func testBlocksNavigationToAnotherHost() {
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(
        url("https://attacker.example/collect"), expected: url("http://127.0.0.1:5173")))
    XCTAssertFalse(
      PreviewNavigationPolicy.allows(
        url("http://evil.test/"), expected: url("http://127.0.0.1:5173")))
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
        PreviewNavigationPolicy.allows(url(bad), expected: url("http://127.0.0.1:5173")),
        "expected \(bad) to be blocked")
    }
  }

  /// WKWebView navigates here internally; blocking it breaks ordinary loads.
  func testAllowsAboutBlank() {
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(url("about:blank"), expected: url("http://127.0.0.1:5173")))
  }

  /// With nothing expected, nothing is verifiable — not even loopback, which
  /// used to be allowed unconditionally and was exactly the hole above.
  func testBlocksEverythingWhenNoExpectedURLIsKnown() {
    XCTAssertFalse(PreviewNavigationPolicy.allows(url("http://example.com/"), expected: nil))
    XCTAssertFalse(PreviewNavigationPolicy.allows(url("http://127.0.0.1/"), expected: nil))
    XCTAssertFalse(PreviewNavigationPolicy.allows(url("http://localhost:5173/"), expected: nil))
  }

  /// Host comparison must not be case-sensitive, or `LOCALHOST` slips through
  /// the loopback check and `EXAMPLE.com` fails the same-host check.
  func testHostMatchingIsCaseInsensitive() {
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(
        url("http://LOCALHOST:3000/"), expected: url("http://localhost:3000")))
    XCTAssertTrue(
      PreviewNavigationPolicy.allows(
        url("http://EXAMPLE.com/"), expected: url("http://example.com:3000")))
  }

  /// The policy is only enforced if WebKit can find the delegate method. A
  /// signature that drifts from the SDK's — the Swift 6 move made the decision
  /// handler `@MainActor` — still compiles, with nothing but a "nearly matches"
  /// warning, and the method is no longer exported under the selector WebKit
  /// asks for. Every navigation is then allowed.
  func testControllerExposesTheNavigationPolicyHook() {
    XCTAssertTrue(
      PreviewController.instancesRespond(
        to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
  }
}
