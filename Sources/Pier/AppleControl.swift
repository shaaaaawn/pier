import Foundation

/// Lifecycle and cleanup for Apple's `container` engine.
///
/// The surface mirrors Docker's closely, with three differences that matter:
///  * there is **no aggregate `system prune`** — containers, images and volumes
///    are pruned separately, so the menu offers them separately;
///  * there is **no restart** command, so Pier doesn't pretend to have one;
///  * prunes take **no `--force`** flag and don't prompt, unlike Docker's, so
///    they're safe to run from a GUI app with no stdin.
enum AppleAction: String, CaseIterable, Identifiable {
  case start
  case stop
  /// Stopped containers only.
  case pruneContainers
  /// Dangling images.
  case pruneImages
  /// Every unused image, not just dangling.
  case pruneImagesAll
  /// Volumes with no container references — deletes data.
  case pruneVolumes
  /// The builder container; recreated on the next build.
  case deleteBuilder

  var id: String { rawValue }

  var title: String {
    switch self {
    case .start: return "Start Containers Service"
    case .stop: return "Stop Containers Service"
    case .pruneContainers: return "Prune Stopped Containers…"
    case .pruneImages: return "Prune Dangling Images…"
    case .pruneImagesAll: return "Prune All Unused Images…"
    case .pruneVolumes: return "Prune Unused Volumes…"
    case .deleteBuilder: return "Delete Builder Container…"
    }
  }

  var arguments: [String] {
    switch self {
    // --enable-kernel-install matters: without it, a first start *prompts* to
    // install the default kernel, and a prompt in a GUI app with no stdin hangs
    // until the timeout instead of starting anything.
    case .start: return ["system", "start", "--enable-kernel-install"]
    case .stop: return ["system", "stop"]
    case .pruneContainers: return ["prune"]
    case .pruneImages: return ["image", "prune"]
    case .pruneImagesAll: return ["image", "prune", "--all"]
    case .pruneVolumes: return ["volume", "prune"]
    case .deleteBuilder: return ["builder", "delete"]
    }
  }

  var needsConfirmation: Bool {
    switch self {
    case .start: return false
    case .stop: return true  // takes every running container with it
    case .pruneContainers, .pruneImages, .pruneImagesAll, .pruneVolumes, .deleteBuilder:
      return true
    }
  }

  var destroysData: Bool { self == .pruneVolumes }

  var confirmMessage: String {
    switch self {
    case .start: return ""
    case .stop:
      return "Stops the container services and every running container."
    case .pruneContainers:
      return "Removes stopped containers. Running ones, images and volumes are untouched."
    case .pruneImages:
      return "Removes dangling (untagged) images only. Tagged images are kept."
    case .pruneImagesAll:
      return "Removes every image no container is using, including tagged ones. "
        + "They'll be pulled again next time they're needed."
    case .pruneVolumes:
      return "Removes volumes with no container references. Volume data cannot be "
        + "recovered — anything a stopped container left behind is deleted."
    case .deleteBuilder:
      return "Deletes the builder container. It's recreated on the next build; "
        + "cached build layers are lost."
    }
  }

  var timeout: TimeInterval {
    switch self {
    // A cold start may fetch the kernel image.
    case .start: return 180
    case .stop: return 90
    default: return 120
    }
  }

  static var lifecycle: [AppleAction] { [.start, .stop] }
  static var cleanup: [AppleAction] {
    [.pruneContainers, .pruneImages, .pruneImagesAll, .pruneVolumes, .deleteBuilder]
  }
}

enum AppleControl {
  /// Classify from a real `container list` result.
  ///
  /// Like Docker, the CLI can **exit 0 while the engine is down** — it prints
  /// `XPC connection error: Connection invalid` plus "Ensure container system
  /// service has been started" and still returns success. So the text is
  /// inspected, not just the exit code.
  static func state(from result: ProcessRunner.Result?, cliInstalled: Bool) -> EngineState {
    guard cliInstalled else { return .cliMissing }
    guard let result else { return .unreachable }
    let text = result.combined.lowercased()
    if text.contains("xpc connection error")
      || text.contains("container system start")
      || text.contains("apiserver is not running")
      || text.contains("internalerror")
    {
      return .unreachable
    }
    guard result.exitCode == 0 else { return .unreachable }
    return .ready
  }

  /// `container system df` — same column shape as Docker's, so the Docker
  /// parser is reused rather than duplicated.
  static func parseDiskUsage(_ output: String) -> [DockerControl.DiskUsage] {
    DockerControl.parseDiskUsage(output)
  }

  static func reclaimableSummary(_ rows: [DockerControl.DiskUsage]) -> String? {
    DockerControl.reclaimableSummary(rows)
  }
}
