import XCTest

@testable import Pier

/// Booted-simulator detection. Command lines are verbatim from this machine
/// (an iPhone and an Apple TV booted in the default set).
final class SimulatorsTests: XCTestCase {
  let devices = "/Users/me/Library/Developer/CoreSimulator/Devices"
  let iphone = "D68F26C2-3570-40C5-A84D-7FF5D6312381"
  let tv = "9EA9727F-73BE-434B-B741-0B574074688A"

  func command(_ set: String, _ udid: String) -> String {
    "launchd_sim \(set)/\(udid)/data/var/run/launchd_bootstrap.plist"
  }

  func plist(name: String, runtime: String) -> Data {
    try! PropertyListSerialization.data(
      fromPropertyList: ["name": name, "runtime": runtime, "UDID": "x", "state": 3],
      format: .xml, options: 0)
  }

  // MARK: - Command line → device

  func testRefFromDefaultSet() {
    let ref = SimulatorParser.ref(fromLaunchdSimCommand: command(devices, iphone))
    XCTAssertEqual(ref, SimulatorRef(udid: iphone, deviceSet: devices))
  }

  /// XCTest clones live outside the default set, and a bare `simctl shutdown`
  /// can't find them — the set has to come from the path.
  func testRefFromXCTestDevicesSet() {
    let set = "/Users/me/Library/Developer/XCTestDevices"
    XCTAssertEqual(
      SimulatorParser.ref(fromLaunchdSimCommand: command(set, tv)),
      SimulatorRef(udid: tv, deviceSet: set))
  }

  /// A custom `--set` path with a space survives: everything after argv[0] is
  /// one path, and the UUID is found by position, not by splitting on spaces.
  func testRefFromSetWithSpace() {
    let set = "/Users/me/Sim Sets/ci"
    XCTAssertEqual(
      SimulatorParser.ref(fromLaunchdSimCommand: command(set, iphone)),
      SimulatorRef(udid: iphone, deviceSet: set))
  }

  func testRefRejectsUnrecognisedCommands() {
    XCTAssertNil(SimulatorParser.ref(fromLaunchdSimCommand: "launchd_sim"))
    XCTAssertNil(SimulatorParser.ref(fromLaunchdSimCommand: "launchd_sim /tmp/whatever.plist"))
    // A UUID that isn't the device directory (no `data/` after it).
    XCTAssertNil(
      SimulatorParser.ref(fromLaunchdSimCommand: "launchd_sim /x/\(iphone)/other/file"))
    // No set before the UUID.
    XCTAssertNil(SimulatorParser.ref(fromLaunchdSimCommand: "launchd_sim \(iphone)/data/x"))
  }

  func testIsUUID() {
    XCTAssertTrue(SimulatorParser.isUUID(iphone))
    XCTAssertTrue(SimulatorParser.isUUID(iphone.lowercased()))
    XCTAssertFalse(SimulatorParser.isUUID("D68F26C2-3570-40C5-A84D"))
    XCTAssertFalse(SimulatorParser.isUUID("G68F26C2-3570-40C5-A84D-7FF5D6312381"))
  }

  // MARK: - device.plist

  func testRuntimeLabels() {
    let p = "com.apple.CoreSimulator.SimRuntime."
    XCTAssertEqual(SimulatorParser.runtimeLabel(p + "iOS-26-5"), "iOS 26.5")
    XCTAssertEqual(SimulatorParser.runtimeLabel(p + "tvOS-27-0"), "tvOS 27.0")
    XCTAssertEqual(SimulatorParser.runtimeLabel(p + "watchOS-12-0"), "watchOS 12.0")
    XCTAssertEqual(SimulatorParser.runtimeLabel(p + "xrOS-3-0"), "visionOS 3.0")
    XCTAssertEqual(SimulatorParser.runtimeLabel("odd"), "odd")
  }

  func testDeviceInfo() {
    let info = SimulatorParser.deviceInfo(
      plist: plist(name: "iPhone 17 Pro", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"))
    XCTAssertEqual(info?.name, "iPhone 17 Pro")
    XCTAssertEqual(info?.runtime, "iOS 26.5")
    XCTAssertNil(SimulatorParser.deviceInfo(plist: Data("not a plist".utf8)))
  }

  // MARK: - Rows

  /// One row per `launchd_sim`; usage is the whole device's process subtree,
  /// and processes outside it don't leak in.
  func testEntriesSumTheDeviceSubtree() {
    let table = ProcessTable.parse(
      """
        1     0  0.0     100 launchd
      500     1  0.5   20000 launchd_sim
      501   500 12.0  400000 SpringBoard
      502   501  3.0  100000 MyApp
      600     1  0.2   10000 launchd_sim
      601   600  1.0   50000 PineBoard
      700     1 50.0  900000 Xcode
      """)
    let commands: [Int32: String] = [
      500: command(devices, iphone), 600: command(devices, tv), 700: "/Applications/Xcode",
    ]
    let plists = [
      "\(devices)/\(iphone)/device.plist": plist(
        name: "iPhone 17 Pro", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"),
      "\(devices)/\(tv)/device.plist": plist(
        name: "Apple TV 4K", runtime: "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"),
    ]
    let rows = SimulatorParser.entries(table: table, commands: commands) { plists[$0] }

    XCTAssertEqual(rows.map(\.name), ["iPhone 17 Pro", "Apple TV 4K"])
    XCTAssertEqual(rows.map(\.detail), ["iOS 26.5", "tvOS 27.0"])
    XCTAssertEqual(rows.map(\.kind), [.simulator, .simulator])
    XCTAssertEqual(rows[0].pids, [500])
    XCTAssertEqual(rows[0].usage, Usage(cpu: 15.5, rssKB: 520_000))
    XCTAssertEqual(rows[1].usage, Usage(cpu: 1.2, rssKB: 60_000))
    XCTAssertEqual(rows[0].simulator, SimulatorRef(udid: iphone, deviceSet: devices))
    XCTAssertTrue(rows.allSatisfy(\.isRunning))
  }

  /// A device whose plist can't be read still gets a row — it's still using
  /// memory, and it can still be shut down by UDID.
  func testEntryWithoutPlistFallsBackToUDID() {
    let table = ProcessTable.parse("500 1 0 1000 launchd_sim")
    let rows = SimulatorParser.entries(table: table, commands: [500: command(devices, iphone)]) {
      _ in nil
    }
    XCTAssertEqual(rows.map(\.name), ["Simulator D68F26C2"])
    XCTAssertNotNil(rows.first?.simulator)
  }

  func testNoSimulatorsReadsNothing() {
    let table = ProcessTable.parse("1 0 0 100 launchd\n700 1 1 100 Xcode")
    var reads = 0
    let rows = SimulatorParser.entries(table: table, commands: [:]) { _ in
      reads += 1
      return nil
    }
    XCTAssertTrue(rows.isEmpty)
    XCTAssertEqual(reads, 0)
  }

  func testDescendantsSurvivesACycle() {
    // pid reuse between two `ps` rows can briefly produce a loop.
    let table = ProcessTable.parse("10 11 0 1 a\n11 10 0 1 b\n12 11 0 1 c")
    let found = table.descendants(of: 10, children: table.childrenIndex())
    XCTAssertEqual(Set(found), [10, 11, 12])
  }

  // MARK: - Actions

  /// Always addressed by set + UDID, as argv: never a shell, never the bare
  /// UDID form that misses XCTest clones.
  func testShutdownArguments() {
    let ref = SimulatorRef(udid: iphone, deviceSet: "/Users/me/Sim Sets/ci")
    XCTAssertEqual(
      SimulatorParser.shutdownArguments(ref),
      ["simctl", "--set", "/Users/me/Sim Sets/ci", "shutdown", iphone])
    XCTAssertEqual(
      SimulatorParser.shutdownAllArguments(deviceSet: devices),
      ["simctl", "--set", devices, "shutdown", "all"])
  }

  func testKindPresentation() {
    XCTAssertEqual(ActivityKind.simulator.sectionTitle, "Simulators")
    XCTAssertEqual(ActivityKind.simulator.stopVerb, "Shut Down")
    XCTAssertEqual(ActivityKind.mcp.stopVerb, "Kill")
    XCTAssertEqual(ActivityKind.docker.stopVerb, "Stop")
    XCTAssertFalse(
      LogSource.resolve(
        activity: ActivityEntry(kind: .simulator, name: "iPhone", detail: "iOS 26.5")
      ).isAvailable)
  }

  /// No section when nothing is booted: there's no engine to start, so an
  /// empty "Simulators" heading would be noise.
  func testNoSectionWhenNothingIsBooted() {
    let groups = PortMonitor.activityGroups(
      activity: [], matching: "", filter: .all, installedEngines: [.docker, .apple])
    XCTAssertFalse(groups.contains { $0.kind == .simulator })
  }
}

final class SimulatorSparklineTests: XCTestCase {
  /// The sparkline under a simulator row follows the device total, not the
  /// near-idle launchd_sim it's keyed by.
  func testSimulatorHistoryTracksTheDevice() {
    let table = ProcessTable.parse("500 1 0.1 1000 launchd_sim\n501 500 30.0 9000 SpringBoard")
    let sim = ActivityEntry(
      kind: .simulator, name: "iPhone", detail: "iOS 26.5", pids: [500],
      usage: Usage(cpu: 30.1, rssKB: 10_000))
    let readings = MonitorAssembly.cpuReadings(entries: [], activity: [sim], table: table)
    XCTAssertEqual(readings[500], 30.1)
  }
}
