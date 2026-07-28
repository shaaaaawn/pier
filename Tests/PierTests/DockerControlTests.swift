import XCTest

@testable import Pier

final class DockerControlTests: XCTestCase {
  // MARK: - Engine state

  /// State comes from a real API call, never from `docker desktop status`.
  /// Observed on this machine: `docker desktop status` printed `Status running`
  /// while the socket didn't exist and every command failed. Trusting it would
  /// have offered prune buttons that could only error.
  func testUnreachableWhenTheAPIRefuses() {
    let refused = ProcessRunner.Result(
      stdout: "",
      stderr: "failed to connect to the docker API at unix:///Users/s/.docker/run/docker.sock",
      exitCode: 1, timedOut: false)
    XCTAssertEqual(DockerControl.state(from: refused, cliInstalled: true), .unreachable)

    let classic = ProcessRunner.Result(
      stdout: "", stderr: "Cannot connect to the Docker daemon. Is the docker daemon running?",
      exitCode: 1, timedOut: false)
    XCTAssertEqual(DockerControl.state(from: classic, cliInstalled: true), .unreachable)
  }

  /// Some versions exit 0 while printing the connection failure, so the text is
  /// checked even on success.
  func testUnreachableEvenWhenExitCodeIsZero() {
    let sneaky = ProcessRunner.Result(
      stdout: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.",
      stderr: "", exitCode: 0, timedOut: false)
    XCTAssertEqual(DockerControl.state(from: sneaky, cliInstalled: true), .unreachable)
  }

  func testReadyWithNoContainersIsStillReady() {
    // Docker running with nothing up: empty output, exit 0.
    let empty = ProcessRunner.Result(stdout: "", stderr: "", exitCode: 0, timedOut: false)
    XCTAssertEqual(DockerControl.state(from: empty, cliInstalled: true), .ready)
    XCTAssertTrue(DockerControl.state(from: empty, cliInstalled: true).isReady)
  }

  func testCLIMissingBeatsEverything() {
    XCTAssertEqual(DockerControl.state(from: nil, cliInstalled: false), .cliMissing)
  }

  // MARK: - Disk usage

  func testParsesSystemDF() {
    let output = """
      TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
      Images          12        4         5.245GB   3.109GB (59%)
      Containers      6         4         1.2MB     0B (0%)
      Local Volumes   8         2         2.3GB     1.9GB (82%)
      Build Cache     40        0         1.1GB     1.1GB
      """
    let rows = DockerControl.parseDiskUsage(output)
    XCTAssertEqual(rows.count, 4)
    // "Local Volumes" contains a space — the reason columns split on 2+ spaces.
    XCTAssertEqual(rows[2].kind, "Local Volumes")
    XCTAssertEqual(rows[2].reclaimable, "1.9GB (82%)")

    let summary = DockerControl.reclaimableSummary(rows)
    XCTAssertEqual(summary, "Images 3.109GB · Local Volumes 1.9GB · Build Cache 1.1GB")
    XCTAssertFalse(summary?.contains("Containers") ?? true, "0B rows add no information")
  }

  func testNothingReclaimableReturnsNil() {
    let output = """
      TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
      Images          2         2         500MB     0B (0%)
      Containers      2         2         1.2MB     0B (0%)
      """
    XCTAssertNil(DockerControl.reclaimableSummary(DockerControl.parseDiskUsage(output)))
  }

  // MARK: - Actions

  func testActionCommands() {
    XCTAssertEqual(DockerAction.start.arguments, ["desktop", "start"])
    XCTAssertEqual(DockerAction.stop.arguments, ["desktop", "stop"])
    XCTAssertEqual(DockerAction.prune.arguments, ["system", "prune", "-f"])
    XCTAssertEqual(DockerAction.pruneBuilder.arguments, ["builder", "prune", "-af"])
    XCTAssertEqual(DockerAction.pruneAll.arguments, ["system", "prune", "-af", "--volumes"])
  }

  /// Anything that removes something must be confirmed; starting is harmless.
  func testConfirmationPolicy() {
    XCTAssertFalse(DockerAction.start.needsConfirmation)
    XCTAssertFalse(DockerAction.restart.needsConfirmation)
    XCTAssertTrue(DockerAction.stop.needsConfirmation, "stopping kills every container")
    for action in DockerAction.pruning {
      XCTAssertTrue(action.needsConfirmation, "\(action.rawValue) deletes things")
      XCTAssertFalse(action.confirmMessage.isEmpty)
    }
  }

  /// Only the volumes variant is unrecoverable, and its wording has to say so —
  /// the difference between "slower next build" and "your database is gone".
  func testOnlyVolumePruneIsMarkedAsDataLoss() {
    for action in DockerAction.allCases {
      XCTAssertEqual(
        action.destroysData, action == .pruneAll,
        "\(action.rawValue) data-loss flag is wrong")
    }
    XCTAssertTrue(DockerAction.pruneAll.confirmMessage.uppercased().contains("VOLUMES"))
    XCTAssertTrue(DockerAction.pruneAll.confirmMessage.contains("cannot be recovered"))
    // The safe prune must say plainly that named volumes survive.
    let safe = DockerAction.prune.confirmMessage
    XCTAssertTrue(safe.contains("Named volumes"), "must name what it preserves")
    XCTAssertTrue(safe.contains("kept"))
  }

  func testLongRunningActionsGetGenerousTimeouts() {
    XCTAssertGreaterThanOrEqual(DockerAction.start.timeout, 60)
    XCTAssertGreaterThanOrEqual(DockerAction.pruneAll.timeout, 120)
  }
}

/// Apple's `container` engine. Its surface is close to Docker's but differs in
/// three ways that the UI has to respect rather than paper over.
final class AppleControlTests: XCTestCase {
  /// The trap: `container list` **exits 0 while the engine is down**, printing
  /// an XPC error. Exit code alone would report a healthy engine.
  func testEngineDownIsDetectedDespiteExitZero() {
    let down = ProcessRunner.Result(
      stdout: "",
      stderr: """
        Error: internalError: "failed to list containers" (cause: "interrupted: \
        "XPC connection error: Connection invalid"")
        Ensure container system service has been started with `container system start`.
        """,
      exitCode: 0, timedOut: false)
    XCTAssertEqual(AppleControl.state(from: down, cliInstalled: true), .unreachable)
  }

  func testStatusStyleMessageAlsoCountsAsDown() {
    let notRegistered = ProcessRunner.Result(
      stdout: "apiserver is not running and not registered with launchd",
      stderr: "", exitCode: 0, timedOut: false)
    XCTAssertEqual(AppleControl.state(from: notRegistered, cliInstalled: true), .unreachable)
  }

  func testReadyOnACleanListing() {
    let listing = ProcessRunner.Result(
      stdout: "ID  IMAGE  OS  ARCH  STATE\npier-web  nginx  linux  arm64  running",
      stderr: "", exitCode: 0, timedOut: false)
    XCTAssertEqual(AppleControl.state(from: listing, cliInstalled: true), .ready)
    XCTAssertEqual(AppleControl.state(from: nil, cliInstalled: false), .cliMissing)
  }

  /// A first `system start` prompts to install the kernel; a prompt inside a GUI
  /// app with no stdin hangs until the timeout, so the flag is mandatory.
  func testStartAvoidsTheInteractiveKernelPrompt() {
    XCTAssertEqual(
      AppleAction.start.arguments, ["system", "start", "--enable-kernel-install"])
  }

  /// No aggregate `system prune` upstream — each resource type is separate.
  func testPrunesAreSeparatePerResource() {
    XCTAssertEqual(AppleAction.pruneContainers.arguments, ["prune"])
    XCTAssertEqual(AppleAction.pruneImages.arguments, ["image", "prune"])
    XCTAssertEqual(AppleAction.pruneImagesAll.arguments, ["image", "prune", "--all"])
    XCTAssertEqual(AppleAction.pruneVolumes.arguments, ["volume", "prune"])
    // And no --force anywhere: these don't prompt, unlike docker's.
    for action in AppleAction.allCases {
      XCTAssertFalse(action.arguments.contains("-f"), "\(action.rawValue) shouldn't need -f")
      XCTAssertFalse(action.arguments.contains("--force"))
    }
  }

  /// There is no `container restart`, so none is offered.
  func testNoFakeRestartIsOffered() {
    XCTAssertEqual(AppleAction.lifecycle, [.start, .stop])
    XCTAssertFalse(AppleAction.allCases.contains { $0.title.lowercased().contains("restart") })
  }

  func testOnlyVolumePruneDestroysData() {
    for action in AppleAction.allCases {
      XCTAssertEqual(
        action.destroysData, action == .pruneVolumes, "\(action.rawValue) flag is wrong")
    }
    XCTAssertTrue(AppleAction.pruneVolumes.confirmMessage.contains("cannot be recovered"))
    // Dangling-only prune must say tagged images survive.
    XCTAssertTrue(AppleAction.pruneImages.confirmMessage.contains("Tagged images are kept"))
  }

  func testStartIsTheOnlyUnconfirmedAction() {
    for action in AppleAction.allCases {
      XCTAssertEqual(action.needsConfirmation, action != .start, "\(action.rawValue)")
    }
  }

  /// Apple writes sizes with a space before the unit ("624.3 MB"); Docker
  /// doesn't ("3.109GB"). Splitting the reclaimable value on whitespace dropped
  /// the unit and reported a bare number — caught only by running it live.
  func testSizeUnitSurvivesAppleFormatting() {
    XCTAssertEqual(DockerControl.sizeOnly("624.3 MB (100%)"), "624.3 MB")
    XCTAssertEqual(DockerControl.sizeOnly("3.109GB (59%)"), "3.109GB")
    XCTAssertEqual(DockerControl.sizeOnly("1.1GB"), "1.1GB")

    let appleDF = """
      TYPE            TOTAL     ACTIVE    SIZE       RECLAIMABLE
      Images          3         0         624.3 MB   624.3 MB (100%)
      Containers      0         0         0 B        0 B (0%)
      """
    XCTAssertEqual(
      AppleControl.reclaimableSummary(AppleControl.parseDiskUsage(appleDF)),
      "Images 624.3 MB")
  }

  /// `container system df` has the same column shape, so the parser is shared.
  func testSharesTheDiskUsageParser() {
    let output = """
      TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
      Images          4         1         820MB     600MB (73%)
      Containers      2         1         2MB       0B (0%)
      """
    XCTAssertEqual(
      AppleControl.reclaimableSummary(AppleControl.parseDiskUsage(output)), "Images 600MB")
  }
}
