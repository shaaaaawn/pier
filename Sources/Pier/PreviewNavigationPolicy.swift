import Foundation

/// Decides where an inline preview is allowed to navigate.
///
/// Without this, the preview would follow any redirect the previewed page asked
/// for — a `302`, a `<meta refresh>`, or `location = "https://…"` — and Pier
/// would happily make requests to an arbitrary external host. That contradicts
/// the README's stated posture ("the only network activity is the inline
/// preview's `WKWebView` loading the localhost URL you clicked"), and the pages
/// involved are exactly the untrusted kind: whatever happens to be listening on
/// a port, including something an agent started. This policy covers navigation,
/// not subresource requests made by an allowed page.
///
/// The rule is: the host **and, on loopback, the port** Pier asked for. Pier
/// picks both; the page doesn't get to change them.
enum PreviewNavigationPolicy {
  /// Hosts that are always the local machine, whatever `expected` says. The
  /// three spellings are interchangeable: a dev server bound to 127.0.0.1
  /// routinely redirects to `localhost`, and an `::1`-only listener is still
  /// this machine.
  static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

  static func isLoopback(_ host: String) -> Bool {
    loopbackHosts.contains(host.lowercased())
  }

  /// The port a URL effectively addresses. `URL.port` is nil for the scheme's
  /// default, so `http://localhost/` and `http://localhost:80/` are the same
  /// destination and must get the same verdict.
  static func effectivePort(of url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }

  /// `expected` is the URL Pier asked to load. Two rules, in order:
  ///
  ///  * **Loopback is pinned to the port.** `localhost` names hundreds of
  ///    unrelated services, and the previewed page is untrusted — allowing it
  ///    to navigate to *any* local port turned the preview into a request
  ///    forger against every other dev tool on the machine (GET-mutating admin
  ///    endpoints, Docker's API on :2375, hot-reload shutdown routes). Same
  ///    port, any loopback spelling, is the redirect real dev servers actually
  ///    make (127.0.0.1 ↔ localhost ↔ ::1).
  ///  * **Other hosts are pinned to the host.** A port bound to a LAN address
  ///    previews on that address, and legitimate stacks there do shift ports
  ///    on the same host (http→https, app→assets), so the host is the identity.
  static func allows(_ url: URL, expected: URL?) -> Bool {
    // WKWebView navigates to about:blank internally; blocking it breaks loads.
    if url.absoluteString == "about:blank" { return true }

    // Only real web schemes. This is what rejects `file:`, `data:`,
    // `javascript:` and any custom scheme that would hand the page a way out.
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return false
    }
    guard let host = url.host?.lowercased() else { return false }

    if isLoopback(host) {
      guard let expected, let expectedHost = expected.host?.lowercased(),
        isLoopback(expectedHost),
        effectivePort(of: url) == effectivePort(of: expected)
      else { return false }
      return true
    }
    guard let expectedHost = expected?.host?.lowercased() else { return false }
    return host == expectedHost
  }
}
