import Darwin
import Foundation

// Small facts about a listening row that make the list readable at a glance:
// how long it's been up, whether other machines can reach it, and whether the
// session that started it is gone.

extension PortEntry {
  /// Bound to every interface (`*`, `0.0.0.0`, `::`): other devices on the
  /// network can reach it unless the firewall says otherwise. Labelled "LAN",
  /// not "exposed" — Pier can't see the firewall.
  var isOnLAN: Bool {
    bindAddresses.contains { ["*", "0.0.0.0", "::", "[::]"].contains($0) }
  }

  /// "4m", "2h", "3d" since the process started; nil without a start time.
  func age(now: Date) -> String? {
    guard let startTime else { return nil }
    let started = Double(startTime) / 1_000_000
    return Self.ageText(seconds: now.timeIntervalSince1970 - started)
  }

  static func ageText(seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "<1m" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return "\(s / 86_400)d"
  }
}

enum LAN {
  /// This Mac's first IPv4 address on a physical interface (en0, en1…), for
  /// "Copy LAN URL". Local only: `getifaddrs`, no network request.
  static func ipv4() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    var candidates: [(name: String, address: String)] = []
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let ifa = pointer.pointee
      guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
        ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      let name = String(cString: ifa.ifa_name)
      candidates.append(
        (name, String(decoding: host.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)))
    }
    return candidates.first { $0.name.hasPrefix("en") }?.address ?? candidates.first?.address
  }
}

extension DevServers {
  /// Names that mean someone is still minding the process: a shell or
  /// terminal multiplexer it runs in, or a process manager that restarts it.
  static let supervisors: Set<String> = [
    "zsh", "bash", "fish", "sh", "login", "tmux", "screen", "zellij", "pm2", "PM2",
    "supervisord", "overmind", "foreman", "honcho", "nodemon", "launchd_sim",
  ]

  /// A dev server whose session is gone: nothing Pier recognises above it —
  /// no agent, terminal, cmux surface, shell or process manager — and its
  /// chain reaches launchd. Typically an agent started `npm run dev` and has
  /// since exited. "Detached" says what Pier can see; it doesn't claim the
  /// server is unwanted.
  static func isDetached(chain: [ProcessTable.Proc], attribution: Attribution) -> Bool {
    guard attribution == .none, let root = chain.last, root.ppid <= 1 else { return false }
    return !chain.contains { supervisors.contains($0.name) }
  }
}
