import Foundation

/// A public URL for a local port, through a tunnel (Cloudflare, ngrok).
/// Shown on the row it exposes: "LAN" means your network can reach a port;
/// "public" means the internet can.
struct TunnelLink: Equatable, Sendable {
  enum Provider: String, Equatable, Sendable {
    case cloudflare = "cloudflared"
    case ngrok

    var displayName: String {
      switch self {
      case .cloudflare: return "Cloudflare Tunnel"
      case .ngrok: return "ngrok"
      }
    }
  }

  let provider: Provider
  /// nil until the tunnel reports one — a quick tunnel takes a few seconds to
  /// register, and a named Cloudflare tunnel never says.
  var publicURL: URL?

  /// http(s) only: a `tcp://` ngrok address isn't something to open.
  var browsableURL: URL? {
    guard let publicURL, ["http", "https"].contains(publicURL.scheme ?? "") else { return nil }
    return publicURL
  }

  var help: String {
    if let publicURL { return "Public at \(publicURL.absoluteString) via \(provider.displayName)" }
    return "Public via \(provider.displayName) — its address isn't known yet"
  }
}

/// A running tunnel process, as its command line and sockets describe it.
struct TunnelProcess: Equatable, Sendable {
  let pid: Int32
  let provider: TunnelLink.Provider
  /// Local ports it forwards to, from its arguments (`--url`, `ngrok http 3000`).
  var targets: [Int]
  /// Its own loopback listeners: cloudflared's metrics server, ngrok's web
  /// inspector — where it reports its public address.
  var apiPorts: [Int]
}

/// One tunnel's answer: where it goes and what it's called out there.
struct ResolvedTunnel: Equatable, Sendable {
  let pid: Int32
  let provider: TunnelLink.Provider
  let target: Int?
  var publicURL: URL?
}

/// Finding tunnels and reading their addresses. Everything here but
/// `TunnelResolver` is pure: command lines and JSON in, values out.
enum Tunnels {
  static let loopback: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]", "*"]

  static func provider(forCommand command: String) -> TunnelLink.Provider? {
    let argv0 = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    let name = argv0.split(separator: "/").last.map(String.init) ?? ""
    let args = command.split(separator: " ").dropFirst().map(String.init)
    switch name {
    // `cloudflared access …` is the client side of Access, not a tunnel out.
    case "cloudflared":
      return args.contains("tunnel") || args.contains { $0.hasPrefix("--url") } ? .cloudflare : nil
    case "ngrok": return .ngrok
    default: return nil
    }
  }

  /// Ports a tunnel's arguments say it forwards to.
  static func targets(provider: TunnelLink.Provider, command: String) -> [Int] {
    let args = command.split(separator: " ").dropFirst().map(String.init)
    switch provider {
    case .cloudflare:
      // `--url http://localhost:3000` or `--url=localhost:3000`.
      for (i, arg) in args.enumerated() {
        if arg.hasPrefix("--url=") { return localPort(String(arg.dropFirst(6))).map { [$0] } ?? [] }
        if arg == "--url", i + 1 < args.count { return localPort(args[i + 1]).map { [$0] } ?? [] }
      }
      return []
    case .ngrok:
      // `ngrok http 3000`, `ngrok http localhost:3000 --url …`, `ngrok tcp 22`.
      // Flag values (`--url https://x.ngrok.app`, `--region us`) never parse
      // as a local address, so the first one that does is the target.
      guard let verb = args.firstIndex(where: { ["http", "tcp", "tls"].contains($0) }) else {
        return []
      }
      for arg in args[(verb + 1)...] where !arg.hasPrefix("-") {
        if let port = localPort(arg) { return [port] }
      }
      return []
    }
  }

  /// "3000", "localhost:3000", "http://127.0.0.1:3000", "https://localhost"
  /// → the local port; nil for anything that isn't this machine.
  static func localPort(_ address: String) -> Int? {
    func valid(_ port: Int?) -> Int? { port.flatMap { (1...65535).contains($0) ? $0 : nil } }
    if address.allSatisfy(\.isNumber) { return valid(Int(address)) }
    if address.contains("://") {
      guard let url = URL(string: address), let host = url.host, loopback.contains(host) else {
        return nil
      }
      if let port = url.port { return valid(port) }
      switch url.scheme {
      case "http": return 80
      case "https": return 443
      default: return nil
      }
    }
    guard let colon = address.lastIndex(of: ":") else { return nil }
    let host = String(address[..<colon])
    guard loopback.contains(host) else { return nil }
    return valid(Int(address[address.index(after: colon)...]))
  }

  /// Tunnel processes among this refresh's rows.
  static func find(entries: [PortEntry], commands: [Int32: String]) -> [TunnelProcess] {
    var found: [Int32: TunnelProcess] = [:]
    for entry in entries {
      guard let command = commands[entry.pid] else { continue }
      if found[entry.pid] == nil {
        guard let provider = provider(forCommand: command) else { continue }
        found[entry.pid] = TunnelProcess(
          pid: entry.pid, provider: provider,
          targets: targets(provider: provider, command: command), apiPorts: [])
      }
      if entry.proto == .tcp, entry.bindAddresses.contains(where: { loopback.contains($0) }) {
        found[entry.pid]?.apiPorts.append(entry.port)
      }
    }
    return found.values.sorted { $0.pid < $1.pid }
  }

  /// cloudflared's metrics server, `GET /quicktunnel`: `{"hostname": "…"}`,
  /// empty for a named tunnel.
  static func parseQuickTunnel(_ data: Data) -> URL? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let host = object["hostname"] as? String, !host.isEmpty, host.count < 256,
      !host.contains("/")
    else { return nil }
    return URL(string: "https://\(host)")
  }

  /// ngrok's agent API, `GET /api/tunnels`: each tunnel's public URL and the
  /// local address it forwards to.
  static func parseNgrokTunnels(_ data: Data) -> [(publicURL: URL, target: Int?)] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tunnels = object["tunnels"] as? [[String: Any]]
    else { return [] }
    return tunnels.compactMap { tunnel in
      guard let raw = tunnel["public_url"] as? String, raw.count < 512,
        let url = URL(string: raw), url.host != nil
      else { return nil }
      let addr = (tunnel["config"] as? [String: Any])?["addr"] as? String
      return (url, addr.flatMap(localPort))
    }
  }

  /// Name each tunnel's own rows for what they are, and mark the rows they
  /// expose as public.
  static func apply(_ tunnels: [ResolvedTunnel], to entries: inout [PortEntry]) {
    let byPid = Dictionary(grouping: tunnels, by: \.pid)
    for i in entries.indices {
      if let mine = byPid[entries[i].pid], let first = mine.first {
        let targets = mine.compactMap(\.target).map { ":\($0)" }
        entries[i].role =
          targets.isEmpty
          ? first.provider.displayName
          : "\(first.provider.displayName) → \(targets.joined(separator: ", "))"
        continue
      }
      guard entries[i].proto == .tcp,
        let tunnel = tunnels.first(where: { $0.target == entries[i].port })
      else { continue }
      entries[i].tunnel = TunnelLink(provider: tunnel.provider, publicURL: tunnel.publicURL)
    }
  }
}

/// Asks each tunnel for its public address, over its own loopback API, and
/// remembers the answer for as long as the process lives.
///
/// Called from the refresh's background queue; `lock` guards the cache, since
/// nothing stops two refreshes overlapping. A request goes only to a port that
/// lsof says the tunnel process itself is listening on, and only on loopback.
final class TunnelResolver: @unchecked Sendable {
  private struct Known {
    var tunnels: [ResolvedTunnel]
    var askedAt: Date
  }

  private let lock = NSLock()
  private var known: [Int32: Known] = [:]
  private let session = URLSession(configuration: .ephemeral)
  /// A tunnel with no address yet is asked again after this long — quick
  /// tunnels register within seconds; a named one never will, so not hammered.
  static let retryAfter: TimeInterval = 10

  func resolve(_ processes: [TunnelProcess], now: Date = Date()) -> [ResolvedTunnel] {
    lock.lock()
    known = known.filter { pid, _ in processes.contains { $0.pid == pid } }
    lock.unlock()
    return processes.flatMap { process -> [ResolvedTunnel] in
      lock.lock()
      let cached = known[process.pid]
      lock.unlock()
      if let cached,
        cached.tunnels.allSatisfy({ $0.publicURL != nil })
          || now.timeIntervalSince(cached.askedAt) < Self.retryAfter
      {
        return cached.tunnels
      }
      let tunnels = ask(process)
      lock.lock()
      known[process.pid] = Known(tunnels: tunnels, askedAt: now)
      lock.unlock()
      return tunnels
    }
  }

  private func ask(_ process: TunnelProcess) -> [ResolvedTunnel] {
    let fallback = (process.targets.isEmpty ? [nil] : process.targets.map { Optional($0) }).map {
      ResolvedTunnel(pid: process.pid, provider: process.provider, target: $0)
    }
    for port in process.apiPorts {
      switch process.provider {
      case .cloudflare:
        if let data = get(port: port, path: "/quicktunnel"),
          let url = Tunnels.parseQuickTunnel(data)
        {
          return fallback.map {
            var t = $0; t.publicURL = url; return t
          }
        }
      case .ngrok:
        if let data = get(port: port, path: "/api/tunnels") {
          let tunnels = Tunnels.parseNgrokTunnels(data)
          if !tunnels.isEmpty {
            return tunnels.map {
              ResolvedTunnel(
                pid: process.pid, provider: .ngrok, target: $0.target ?? process.targets.first,
                publicURL: $0.publicURL)
            }
          }
        }
      }
    }
    return fallback
  }

  /// A short, synchronous loopback GET. Bounded in time and size: whatever
  /// answers on that port is untrusted.
  private func get(port: Int, path: String) -> Data? {
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
    let request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0.5)
    let result = ProbeResult<Data>()
    let done = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { data, response, _ in
      if (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count < 64 * 1024 {
        result.value = data
      }
      done.signal()
    }
    task.resume()
    // Cancelled on timeout, so a late answer can't write while it's read.
    guard done.wait(timeout: .now() + 0.8) == .success else {
      task.cancel()
      return nil
    }
    return result.value
  }
}
