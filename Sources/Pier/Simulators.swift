import Foundation

// Booted Xcode simulators, detected for free.
//
// Each booted device runs exactly one `launchd_sim`, whose command line names
// the device's directory: `launchd_sim <set>/<UDID>/data/var/run/
// launchd_bootstrap.plist`. Pier already reads every command line on every
// refresh, so detection spawns nothing. Name and runtime come from
// `<set>/<UDID>/device.plist` (microseconds to read) rather than
// `xcrun simctl list`, which measured ~140 ms of CPU per call — nearly as much
// as a whole port refresh. `simctl` runs only when the user asks it to act.

/// Enough to address one device with `simctl`.
struct SimulatorRef: Equatable {
  let udid: String
  /// The device set directory. The default set lives in
  /// `~/Library/Developer/CoreSimulator/Devices`, but XCTest clones live in
  /// `~/Library/Developer/XCTestDevices`, and a bare `simctl shutdown <udid>`
  /// only looks in the default one — so every command passes `--set`.
  let deviceSet: String
}

enum SimulatorParser {
  /// A `launchd_sim` command line → the device it belongs to. The UDID is the
  /// path component directly above `data/`, wherever the set happens to live.
  static func ref(fromLaunchdSimCommand command: String) -> SimulatorRef? {
    // argv[0] is "launchd_sim"; the rest is one path, which may contain spaces.
    guard let space = command.firstIndex(of: " ") else { return nil }
    let path = command[command.index(after: space)...]
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    let deviceDir = parts.indices.dropLast().first {
      isUUID(parts[$0]) && parts[$0 + 1] == "data"
    }
    guard let i = deviceDir else { return nil }
    let set = parts[..<i].joined(separator: "/")
    return set.isEmpty ? nil : SimulatorRef(udid: String(parts[i]), deviceSet: set)
  }

  static func isUUID<S: StringProtocol>(_ s: S) -> Bool {
    let groups = s.split(separator: "-", omittingEmptySubsequences: false)
    guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
    return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
  }

  /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5". visionOS is
  /// still spelled `xrOS` in runtime identifiers.
  static func runtimeLabel(_ identifier: String) -> String {
    let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
    let pieces = tail.split(separator: "-").map(String.init)
    guard let platform = pieces.first, pieces.count > 1 else { return tail }
    let name = platform == "xrOS" ? "visionOS" : platform
    return "\(name) \(pieces.dropFirst().joined(separator: "."))"
  }

  /// `device.plist` → (name, runtime label). nil if it isn't the shape we know.
  static func deviceInfo(plist data: Data) -> (name: String, runtime: String)? {
    guard
      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let name = dict["name"] as? String
    else { return nil }
    let runtime = (dict["runtime"] as? String).map(runtimeLabel) ?? "Simulator"
    return (name, runtime)
  }

  /// One activity row per booted device. Usage is summed over everything
  /// running under the device's `launchd_sim`, so the row answers "which
  /// simulator is eating my RAM" — the question the pressure tint raises.
  /// RSS overcounts shared pages, so it's a guide, not an exact figure.
  static func entries(
    table: ProcessTable, commands: [Int32: String],
    readDevicePlist: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
  ) -> [ActivityEntry] {
    let roots = table.byPid.values.filter { $0.name == "launchd_sim" }.map(\.pid)
    guard !roots.isEmpty else { return [] }
    let children = table.childrenIndex()
    return roots.sorted().compactMap { pid -> ActivityEntry? in
      guard let command = commands[pid], let ref = ref(fromLaunchdSimCommand: command) else {
        return nil
      }
      let info = readDevicePlist("\(ref.deviceSet)/\(ref.udid)/device.plist")
        .flatMap(deviceInfo(plist:))
      let subtree = table.descendants(of: pid, children: children)
      return ActivityEntry(
        kind: .simulator,
        name: info?.name ?? "Simulator \(ref.udid.prefix(8))",
        detail: info?.runtime ?? "Simulator",
        pids: [pid],
        usage: table.usage(for: subtree),
        simulator: ref)
    }
  }

  /// `xcrun simctl --set <set> shutdown <udid>`, as argv — never a shell.
  static func shutdownArguments(_ ref: SimulatorRef) -> [String] {
    ["simctl", "--set", ref.deviceSet, "shutdown", ref.udid]
  }

  /// Every booted device in one set.
  static func shutdownAllArguments(deviceSet: String) -> [String] {
    ["simctl", "--set", deviceSet, "shutdown", "all"]
  }
}

extension ProcessTable {
  /// parent → children, built once per refresh rather than per lookup.
  func childrenIndex() -> [Int32: [Int32]] {
    var index: [Int32: [Int32]] = [:]
    for proc in byPid.values where proc.ppid != proc.pid {
      index[proc.ppid, default: []].append(proc.pid)
    }
    return index
  }

  /// `root` and everything beneath it. Cycle-safe: pids can be reused between
  /// the moments `ps` reads two rows, which can briefly make a loop.
  func descendants(of root: Int32, children: [Int32: [Int32]]) -> [Int32] {
    var result: [Int32] = []
    var seen: Set<Int32> = []
    var queue = [root]
    while let pid = queue.popLast() {
      guard seen.insert(pid).inserted else { continue }
      result.append(pid)
      queue.append(contentsOf: children[pid] ?? [])
    }
    return result
  }
}
