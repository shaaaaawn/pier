import Foundation

/// Decides where an inline preview is allowed to navigate.
///
/// Without this, the preview would follow any redirect the previewed page asked
/// for — a `302`, a `<meta refresh>`, or `location = "https://…"` — and Pier
/// would happily navigate to an arbitrary external host. The pages involved are
/// exactly the untrusted kind: whatever happens to be listening on a port,
/// including something an agent started. This policy covers navigation, not
/// subresource requests made by an allowed page.
///
/// The rule is same-host, plus loopback. Pier picks the host it asks for; the
/// page doesn't get to change it.
enum PreviewNavigationPolicy {
  /// Hosts that are always the local machine, whatever `expectedHost` says.
  static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

  static func isLoopback(_ host: String) -> Bool {
    loopbackHosts.contains(host.lowercased())
  }

  /// `expectedHost` is the host of the URL Pier asked to load — a port bound to
  /// a LAN address previews on that address, so loopback alone is too narrow.
  static func allows(_ url: URL, expectedHost: String?) -> Bool {
    // WKWebView navigates to about:blank internally; blocking it breaks loads.
    if url.absoluteString == "about:blank" { return true }

    // Only real web schemes. This is what rejects `file:`, `data:`,
    // `javascript:` and any custom scheme that would hand the page a way out.
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return false
    }
    guard let host = url.host?.lowercased() else { return false }
    if isLoopback(host) { return true }
    guard let expectedHost = expectedHost?.lowercased() else { return false }
    return host == expectedHost
  }
}
