import Foundation

/// Row ordering for the ports list.
enum PortSort: String, CaseIterable, Identifiable {
  /// Most interesting first — see `ActivityRank`.
  case activity
  case port
  case name

  var id: String { rawValue }

  var label: String {
    switch self {
    case .activity: return "Activity"
    case .port: return "Port"
    case .name: return "Name"
    }
  }

  var symbol: String {
    switch self {
    case .activity: return "bolt"
    case .port: return "number"
    case .name: return "textformat.abc"
    }
  }
}

/// Scores a listener by how likely you are to care about it right now.
///
/// The hard part is that **a dev server idles at 0% CPU between requests**, so
/// instantaneous CPU ranks a busy Vite server below a polling menu bar daemon.
/// Two things fix that: score against the *recent peak* of the CPU series
/// (~2 min) rather than the current sample, and give an outright bonus to
/// things that look like web servers, which is what you open Pier to find.
///
/// Deliberately heuristic-only: identifying a real HTTP server would mean
/// connecting to every port. Pier never probes listeners just to classify them;
/// guessing from the port and process name is honest about being a guess, while
/// probing could trigger side effects on someone's endpoint.
enum ActivityRank {
  /// Ports that are conventionally a dev/web server. Not exhaustive and not
  /// meant to be — it's a ranking nudge, not a classification.
  static let devPorts: Set<Int> = [
    80, 443, 3000, 3001, 3030, 4000, 4200, 4321, 5000, 5001, 5173, 5174, 5432,
    7000, 8000, 8001, 8080, 8081, 8787, 8888, 9000, 9090,
  ]

  /// Process names that serve HTTP more often than not.
  static let webProcesses: Set<String> = [
    "node", "deno", "bun", "workerd", "wrangler", "next", "vite", "nginx",
    "caddy", "httpd", "python", "python3", "ruby", "rails", "puma", "php",
    "gunicorn", "uvicorn", "hugo", "esbuild", "webpack",
  ]

  /// A listener that is probably a web server: reachable from a browser **and**
  /// either on a conventional web port or run by something that usually serves
  /// HTTP. Requiring both keeps a random loopback IPC socket from outranking a
  /// real dev server just because it's bindable.
  static func isLikelyWebServer(_ entry: PortEntry) -> Bool {
    guard entry.previewURL != nil else { return false }
    return devPorts.contains(entry.port) || hasWebProcessName(entry)
  }

  /// The stronger of the two signals: what the process *is*, not where it
  /// happens to be listening. A background daemon can squat :5000; only a
  /// server runtime is named `node`/`workerd`/`uvicorn`.
  static func hasWebProcessName(_ entry: PortEntry) -> Bool {
    let name = entry.processName.lowercased()
    // Prefix match: lsof reports "python3.11", "node", "Cursor Helper (Plugin)".
    return webProcesses.contains { name == $0 || name.hasPrefix($0 + ".") }
  }

  /// Higher sorts first. The bands are far enough apart that a category never
  /// gets swamped by CPU noise from the band below it.
  static func score(_ entry: PortEntry, series: [Double]) -> Double {
    var score = 0.0
    if isLikelyWebServer(entry) {
      // Two tiers: a server runtime is real evidence, a conventional port
      // number is only a hint. Flat scoring let anything squatting :5000
      // outrank a genuine dev server.
      score += hasWebProcessName(entry) ? 1_000 : 500
    }
    // A system daemon on a privileged port is rarely what you came for, and
    // this outweighs the web bonus so httpd doesn't top the list over your app.
    if entry.attribution == .system { score -= 1_500 }
    // Yours, and traceable to an agent or a cmux surface.
    switch entry.attribution {
    case .cmux, .harness: score += 300
    case .system, .none: break
    }
    // Recent peak, not the current sample: a compile spike two minutes ago is
    // better evidence of "in use" than this instant's idle reading.
    let peak = min(series.max() ?? 0, 100)
    score += peak * 4
    score += min(entry.usage?.cpu ?? 0, 100) * 2
    return score
  }

  /// Sort comparator for two entries under a given mode. Every mode falls back
  /// to port then id, so ordering is **total** — an unstable list that reshuffles
  /// on each 5s refresh is worse than a wrong order.
  static func areInOrder(
    _ a: PortEntry, _ b: PortEntry, sort: PortSort, history: UsageHistory
  ) -> Bool {
    switch sort {
    case .port:
      break
    case .name:
      let left = a.processName.lowercased()
      let right = b.processName.lowercased()
      if left != right { return left < right }
    case .activity:
      let left = score(a, series: history.series(for: a.pid))
      let right = score(b, series: history.series(for: b.pid))
      if left != right { return left > right }
    }
    if a.port != b.port { return a.port < b.port }
    return a.id < b.id
  }
}
