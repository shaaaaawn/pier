import XCTest

@testable import Pier

final class FilterTests: XCTestCase {
  private func entry(
    _ pid: Int32, _ port: Int, _ name: String, proto: PortProtocol = .tcp,
    attr: Attribution = .none
  ) -> PortEntry {
    PortEntry(
      pid: pid, port: port, proto: proto, processName: name, user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: attr)
  }

  private var sample: [PortEntry] {
    [
      entry(1, 3000, "node", attr: .harness("Claude Code")),
      entry(2, 5353, "mDNSRespo", proto: .udp, attr: .system),
      entry(3, 8080, "caddy"),
    ]
  }

  // MARK: - Scope chips

  /// Web was removed as a near-duplicate of Ports. A saved "web" opens on
  /// Ports; anything unknown falls back to All.
  func testSavedWebScopeOpensOnPorts() {
    XCTAssertEqual(PierFilter.stored("web"), .ports)
    XCTAssertEqual(PierFilter.stored("mcp"), .mcp)
    XCTAssertEqual(PierFilter.stored("nonsense"), .all)
    XCTAssertFalse(PierFilter.allCases.map(\.rawValue).contains("web"))
  }

  func testPortsScopeKeepsUDPToo() {
    let visible = PortMonitor.visibleEntries(sample, filter: .ports, hideSystem: false)
    XCTAssertEqual(visible.map(\.port), [3000, 5353, 8080])
  }

  func testContainerAndMCPScopesHideAllPorts() {
    for filter in [PierFilter.containers, .mcp] {
      XCTAssertTrue(
        PortMonitor.visibleEntries(sample, filter: filter, hideSystem: false).isEmpty,
        "\(filter) should list no port rows")
    }
  }

  func testHideSystemDropsSystemAttributedRows() {
    let visible = PortMonitor.visibleEntries(sample, filter: .all, hideSystem: true)
    XCTAssertEqual(visible.map(\.port), [3000, 8080])
  }

  func testScopeActivityKinds() {
    XCTAssertEqual(PierFilter.all.activityKinds, [.docker, .apple, .simulator, .mcp])
    XCTAssertEqual(PierFilter.containers.activityKinds, [.docker, .apple, .simulator])
    XCTAssertEqual(PierFilter.mcp.activityKinds, [.mcp])
    XCTAssertTrue(PierFilter.ports.activityKinds.isEmpty)
  }

  @MainActor
  func testVisibleCountCombinesPortsAndActivity() {
    let activity = [
      ActivityEntry(kind: .docker, name: "web", detail: "nginx · Up"),
      ActivityEntry(kind: .mcp, name: "node · mcp-fs", detail: "cmd", pids: [9, 10]),
    ]
    let monitor = PortMonitor(fixture: sample, activity: activity)
    // 3 ports + 1 docker + 2 grouped mcp pids
    XCTAssertEqual(monitor.visibleCount(matching: "", filter: .all, hideSystem: false), 6)
    // MCP scope: just the two grouped pids.
    XCTAssertEqual(monitor.visibleCount(matching: "", filter: .mcp, hideSystem: false), 2)
    // Ports scope: every port, no activity.
    XCTAssertEqual(monitor.visibleCount(matching: "", filter: .ports, hideSystem: false), 3)
  }

  // MARK: - Preview viewport

  func testViewportZoomTargetsRequestedCSSWidth() {
    let cardWidth: CGFloat = 456
    let zoom = PreviewViewport.desktop.zoom(cardWidth: cardWidth)
    // pageZoom reflows, so cardWidth / zoom is the CSS viewport the page sees.
    XCTAssertEqual(cardWidth / zoom, 1280, accuracy: 1.0)
    XCTAssertEqual(
      cardWidth / PreviewViewport.laptop.zoom(cardWidth: cardWidth), 1024, accuracy: 1.0)
  }

  func testNativeViewportDoesNotZoom() {
    XCTAssertEqual(PreviewViewport.native.zoom(cardWidth: 456), 1)
  }

  func testViewportZoomClampedAndSafeAtZeroWidth() {
    XCTAssertEqual(PreviewViewport.desktop.zoom(cardWidth: 0), 1)
    // A card wider than the target never zooms in past 1:1.
    XCTAssertEqual(PreviewViewport.laptop.zoom(cardWidth: 2000), 1)
    // Very narrow cards clamp instead of collapsing to an unusable zoom.
    XCTAssertEqual(PreviewViewport.wide.zoom(cardWidth: 50), 0.2, accuracy: 0.001)
  }

  func testDesktopPresetsUse16by10Aspect() {
    XCTAssertEqual(PreviewViewport.desktop.aspect, 0.625, accuracy: 0.001)
    XCTAssertNotEqual(PreviewViewport.native.aspect, PreviewViewport.desktop.aspect)
  }
}

/// Section ordering: containers and MCP are things you chose to run, so they
/// sit above the "Other"/"System" catch-alls rather than after them.
final class SectionOrderTests: XCTestCase {
  private func portGroup(_ title: String, rank: Int) -> PortGroup {
    PortGroup(title: title, rank: rank, rows: [])
  }

  func testContainersAndMCPComeBeforeOtherAndSystem() {
    let ports = [
      portGroup("Claude Code", rank: 0),
      portGroup("Other", rank: 1),
      portGroup("System", rank: 2),
    ]
    let activity = [
      ActivityGroup(kind: .docker, entries: []),
      ActivityGroup(kind: .apple, entries: []),
      ActivityGroup(kind: .mcp, entries: []),
    ]
    let titles = PierSection.ordered(ports: ports, activity: activity).map { section -> String in
      switch section {
      case .ports(let group): return group.title
      case .activity(let group): return group.title
      }
    }
    XCTAssertEqual(
      titles,
      ["Claude Code", "Docker", "Apple Containers", "MCP Servers", "Other", "System"])
  }

  func testOrderingHoldsWithNoAttributedGroups() {
    let ports = [portGroup("Other", rank: 1)]
    let activity = [ActivityGroup(kind: .docker, entries: [])]
    let titles = PierSection.ordered(ports: ports, activity: activity).map { section -> String in
      switch section {
      case .ports(let group): return group.title
      case .activity(let group): return group.title
      }
    }
    XCTAssertEqual(titles, ["Docker", "Other"])
  }

  func testEmptyInputsProduceNoSections() {
    XCTAssertTrue(PierSection.ordered(ports: [], activity: []).isEmpty)
  }
}

/// An installed engine keeps its section even with no containers.
///
/// The regression this prevents: Docker ready but idle produced no Docker
/// section, and the section header is the only place its Start/Stop/prune menu
/// lives — so a running engine (with 397MB of reclaimable volumes) had no reachable
/// controls at all, and the "engine down" banner didn't apply either.
final class EmptyEngineSectionTests: XCTestCase {
  private let mcpOnly = [
    ActivityEntry(kind: .mcp, name: "node · mcp-fs", detail: "cmd", pids: [1])
  ]

  func testInstalledEngineKeepsItsSectionWhenIdle() {
    let groups = PortMonitor.activityGroups(
      activity: mcpOnly, matching: "", filter: .all, installedEngines: [.docker, .apple])
    XCTAssertEqual(groups.map(\.kind), [.docker, .apple, .mcp])
    XCTAssertTrue(groups[0].entries.isEmpty, "empty, but present so its menu is reachable")
    XCTAssertEqual(groups[0].entryCount, 0)
  }

  func testUninstalledEngineStaysHidden() {
    let groups = PortMonitor.activityGroups(
      activity: mcpOnly, matching: "", filter: .all, installedEngines: [])
    XCTAssertEqual(groups.map(\.kind), [.mcp], "no CLI, nothing to control, no section")
  }

  /// MCP has no controls, so an empty MCP section would be pure noise.
  func testEmptyMCPSectionStaysHidden() {
    let groups = PortMonitor.activityGroups(
      activity: [], matching: "", filter: .mcp, installedEngines: [.docker, .apple])
    XCTAssertTrue(groups.isEmpty)
  }

  /// While searching, an empty section is misleading — "no matches" is the answer.
  func testSearchHidesEmptySections() {
    let docker = [ActivityEntry(kind: .docker, name: "web", detail: "nginx · Up")]
    let matching = PortMonitor.activityGroups(
      activity: docker, matching: "nginx", filter: .all, installedEngines: [.docker, .apple])
    XCTAssertEqual(matching.map(\.kind), [.docker])

    let notMatching = PortMonitor.activityGroups(
      activity: docker, matching: "zzz", filter: .all, installedEngines: [.docker, .apple])
    XCTAssertTrue(notMatching.isEmpty, "a search must not resurrect empty sections")
  }

  func testScopeStillNarrows() {
    let groups = PortMonitor.activityGroups(
      activity: [], matching: "", filter: .containers, installedEngines: [.docker, .apple])
    XCTAssertEqual(groups.map(\.kind), [.docker, .apple])

    XCTAssertTrue(
      PortMonitor.activityGroups(
        activity: [], matching: "", filter: .ports, installedEngines: [.docker, .apple]
      ).isEmpty, "Ports scope shows no engine sections")
  }
}
