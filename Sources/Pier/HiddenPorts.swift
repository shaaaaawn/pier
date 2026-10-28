import Foundation

/// Ports the user has hidden. They keep running; Pier just stops listing them —
/// in the list, the counts, the search, the event feed and the menu bar
/// tooltip — the way LeftOpen's hidden ports work.
///
/// Stored as "3000, 5353" so the Settings field and the defaults domain read
/// the same.
enum HiddenPorts {
  static let defaultsKey = "hiddenPorts"

  /// Lenient: commas, spaces or newlines between ports; anything that isn't a
  /// valid port number (1–65535) is ignored.
  static func parse(_ text: String) -> Set<Int> {
    Set(
      text.split(whereSeparator: { ",; \n\t".contains($0) })
        .compactMap { Int($0) }
        .filter { (1...65535).contains($0) })
  }

  static func format(_ ports: Set<Int>) -> String {
    ports.sorted().map(String.init).joined(separator: ", ")
  }

  /// Read on the refresh queue: UserDefaults is thread-safe.
  static func current(_ defaults: UserDefaults = .standard) -> Set<Int> {
    parse(defaults.string(forKey: defaultsKey) ?? "")
  }

  static func set(_ ports: Set<Int>, _ defaults: UserDefaults = .standard) {
    defaults.set(format(ports), forKey: defaultsKey)
  }

  static func hide(_ port: Int, _ defaults: UserDefaults = .standard) {
    set(current(defaults).union([port]), defaults)
  }
}
