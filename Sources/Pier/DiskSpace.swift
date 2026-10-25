import Foundation

/// Free space on the startup volume, for the footer glance.
///
/// Three ways to ask, measured on the dev machine, and they disagree:
///
/// | API | reported | cost |
/// |---|---|---|
/// | `statfs` (`f_bavail`) | 88.7 GB | 0.8 µs |
/// | `volumeAvailableCapacityKey` | 88.7 GB | 121 µs |
/// | `volumeAvailableCapacityForImportantUsageKey` | 91.9 GB | 11.5 ms |
///
/// The headline is `statfs`: what is actually free right now, the same figure
/// `df` and `diskutil`'s "Container Free Space" print. Finder's "Available"
/// adds purgeable space macOS *can* reclaim on demand; that number goes in the
/// tooltip, so Pier never looks like it disagrees with Finder, and its 11.5 ms
/// cost is paid only on the once-a-minute refresh.
struct DiskSnapshot: Equatable {
  var free: UInt64
  var total: UInt64
  /// Finder's "Available": free plus purgeable. nil if the query failed.
  var availableIncludingPurgeable: UInt64?

  /// Whole gigabytes are the display precision, so that's the publish gate.
  var displayKey: [Int] {
    [free, total, availableIncludingPurgeable ?? 0].map { Int($0 / 1_000_000_000) }
  }
}

enum DiskSpace {
  /// The startup volume. On APFS `/` reports the whole container's free space,
  /// which is what the system and data volumes actually share.
  static func read(path: String = "/") -> DiskSnapshot? {
    var stats = statfs()
    guard statfs(path, &stats) == 0 else { return nil }
    let block = UInt64(stats.f_bsize)
    // A fresh URL each time: resource values are cached per URL instance, and a
    // cached "available" would never move.
    let available =
      (try? URL(fileURLWithPath: path)
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage
    return DiskSnapshot(
      free: UInt64(stats.f_bavail) * block,
      total: UInt64(stats.f_blocks) * block,
      availableIncludingPurgeable: available.flatMap { $0 >= 0 ? UInt64($0) : nil })
  }

  /// "89 GB free". Base-10 units, like Finder and `df -H` — unlike RAM, which
  /// uses the binary units Activity Monitor uses.
  static func format(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1e9
    return gb < 1000 ? String(format: "%.0f GB", gb) : String(format: "%.1f TB", gb / 1000)
  }
}
