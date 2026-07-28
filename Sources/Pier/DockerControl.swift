import Foundation

/// Whether Pier can drive a container engine, decided by whether the engine
/// **answers** — not by what its status command claims.
///
/// That distinction is load-bearing: on this machine `docker desktop status`
/// reported `Status running` while the API socket didn't exist and every command
/// failed with "failed to connect to the docker API". Trusting status would have
/// offered prune buttons that could only error.
enum EngineState: Equatable {
  case cliMissing
  /// CLI present, daemon not answering — the actionable case (offer Start).
  case unreachable
  case ready

  var isReady: Bool { self == .ready }
}

/// Docker lifecycle and cleanup actions offered from the panel.
enum DockerAction: String, CaseIterable, Identifiable {
  case start
  case stop
  case restart
  /// Stopped containers, unused networks, dangling images, build cache.
  case prune
  case pruneImages
  case pruneBuilder
  /// Everything unused **including volumes** — deletes data.
  case pruneAll

  var id: String { rawValue }

  var title: String {
    switch self {
    case .start: return "Start Docker"
    case .stop: return "Stop Docker"
    case .restart: return "Restart Docker"
    case .prune: return "Prune Unused…"
    case .pruneImages: return "Prune Images…"
    case .pruneBuilder: return "Prune Build Cache…"
    case .pruneAll: return "Prune Everything, Including Volumes…"
    }
  }

  var arguments: [String] {
    switch self {
    case .start: return ["desktop", "start"]
    case .stop: return ["desktop", "stop"]
    case .restart: return ["desktop", "restart"]
    case .prune: return ["system", "prune", "-f"]
    case .pruneImages: return ["image", "prune", "-af"]
    case .pruneBuilder: return ["builder", "prune", "-af"]
    case .pruneAll: return ["system", "prune", "-af", "--volumes"]
    }
  }

  /// Actions that delete something get a confirmation; lifecycle ones don't.
  var needsConfirmation: Bool {
    switch self {
    case .start, .restart: return false
    case .stop: return true  // stopping the engine stops every container
    case .prune, .pruneImages, .pruneBuilder, .pruneAll: return true
    }
  }

  /// Irreversible data loss — the UI marks these differently.
  var destroysData: Bool { self == .pruneAll }

  var confirmMessage: String {
    switch self {
    case .stop:
      return "Stops the Docker engine and every running container."
    case .prune:
      return "Removes stopped containers, unused networks, dangling images, and "
        + "the build cache. Named volumes and tagged images are kept."
    case .pruneImages:
      return "Removes every image not used by a container, including tagged ones. "
        + "They'll be pulled again next time they're needed."
    case .pruneBuilder:
      return "Clears the build cache. Next builds are slower but nothing is lost."
    case .pruneAll:
      return "Removes all unused containers, images, networks AND VOLUMES. "
        + "Volume data cannot be recovered — database contents in unused volumes "
        + "are deleted."
    case .start, .restart:
      return ""
    }
  }

  /// Long-running: engine start and big prunes need a generous timeout.
  var timeout: TimeInterval {
    switch self {
    case .start, .restart, .stop: return 90
    case .prune, .pruneImages, .pruneBuilder, .pruneAll: return 180
    }
  }

  static var lifecycle: [DockerAction] { [.start, .stop, .restart] }
  static var pruning: [DockerAction] { [.prune, .pruneImages, .pruneBuilder, .pruneAll] }
}

enum DockerControl {
  /// One row of `docker system df`.
  struct DiskUsage: Equatable {
    let kind: String
    let size: String
    let reclaimable: String
  }

  /// Classify from a real API call's result (e.g. `docker ps`).
  static func state(from result: ProcessRunner.Result?, cliInstalled: Bool) -> EngineState {
    guard cliInstalled else { return .cliMissing }
    guard let result else { return .unreachable }
    if result.exitCode != 0 { return .unreachable }
    let text = result.combined.lowercased()
    // Docker exits 0 in some versions while printing a connection failure.
    if text.contains("cannot connect to the docker daemon")
      || text.contains("failed to connect to the docker api")
      || text.contains("is the docker daemon running")
    {
      return .unreachable
    }
    return .ready
  }

  /// Parse `docker system df`. Columns are space-padded and some type names
  /// contain a space ("Local Volumes"), so split on runs of 2+ spaces.
  static func parseDiskUsage(_ output: String) -> [DiskUsage] {
    output.split(separator: "\n")
      .dropFirst()  // header
      .compactMap { line in
        let columns = line.components(separatedBy: "  ")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        guard columns.count >= 4 else { return nil }
        return DiskUsage(
          kind: columns[0], size: columns[columns.count - 2],
          reclaimable: columns[columns.count - 1])
      }
  }

  /// "Images 3.1GB · Build Cache 1.1GB" — only rows with something to reclaim,
  /// so a prune confirmation can say what it would actually free.
  static func reclaimableSummary(_ rows: [DiskUsage]) -> String? {
    let meaningful = rows.filter { row in
      let value = row.reclaimable
      // "0B", "0B (0%)" and empty all mean nothing to gain.
      return !value.isEmpty && !value.hasPrefix("0B") && !value.hasPrefix("0 ")
    }
    guard !meaningful.isEmpty else { return nil }
    return
      meaningful
      .map { "\($0.kind) \(Self.sizeOnly($0.reclaimable))" }
      .joined(separator: " · ")
  }

  /// "3.109GB (59%)" → "3.109GB", and "624.3 MB (100%)" → "624.3 MB".
  ///
  /// Drop the percentage, not everything after the first space: Docker writes
  /// `3.109GB` but Apple's `container system df` writes `624.3 MB` with a space
  /// before the unit, and splitting on space silently reported "624.3" —
  /// a number with no unit.
  static func sizeOnly(_ reclaimable: String) -> String {
    let withoutPercent =
      reclaimable.components(separatedBy: "(").first ?? reclaimable
    return withoutPercent.trimmingCharacters(in: .whitespaces)
  }
}
