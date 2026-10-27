import XCTest

@testable import Pier

/// "Is my Mac hot, and who's doing it?" — thermal state, CPU load, culprits.
final class SystemLoadTests: XCTestCase {
  func testThermalStateMapsAndEscalates() {
    XCTAssertEqual(ThermalLevel(.nominal), .nominal)
    XCTAssertEqual(ThermalLevel(.critical), .critical)
    XCTAssertLessThan(ThermalLevel.fair, .serious)
    XCTAssertFalse(ThermalLevel.fair.isHot, "Warm is routine under a build; not a red flag")
    XCTAssertTrue(ThermalLevel.serious.isHot)
  }

  /// One dot means "under strain": memory pressure or heat, whichever is worse.
  func testHeatSharesThePressureDot() {
    XCTAssertEqual(StatusTitle.make(unseen: 0, pressure: .normal, thermal: .fair).length, 0)
    XCTAssertEqual(StatusTitle.make(unseen: 0, pressure: .normal, thermal: .serious).string, " ●")
    XCTAssertEqual(MemoryPressure.worst(.warning, ThermalLevel.critical.asStrain), .critical)
    XCTAssertEqual(MemoryPressure.worst(.critical, ThermalLevel.serious.asStrain), .critical)
  }

  func testCPUUsageFromTickDeltas() {
    let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
    let b = CPUTicks(user: 160, system: 80, idle: 910, nice: 0)
    // 90 busy of 150 elapsed.
    XCTAssertEqual(CPULoad.usage(previous: a, current: b) ?? -1, 0.6, accuracy: 1e-9)
    XCTAssertNil(CPULoad.usage(previous: nil, current: b))
    XCTAssertNil(CPULoad.usage(previous: b, current: a), "a counter reset is not a reading")
    XCTAssertEqual(CPULoad.format(0.355), "36%")
  }

  func testLiveCPUReadingIsPlausible() throws {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let ticks = try XCTUnwrap(CPULoad.read(host: host))
    XCTAssertGreaterThan(ticks.total, 0)
  }

  /// Forty helpers are one culprit: aggregated by name, idle noise dropped.
  func testBusiestAggregatesByName() {
    let table = ProcessTable.parse(
      """
      1 0 0.0 100 launchd
      10 1 30.0 100 Browser Helper
      11 1 25.0 100 Browser Helper
      20 1 40.0 100 WindowServer
      30 1 0.5 100 cloudd
      40 1 12.0 100 node
      """)
    let top = table.busiest()
    XCTAssertEqual(top.map(\.name), ["Browser Helper", "WindowServer", "node"])
    XCTAssertEqual(top[0].label, "Browser Helper ×2 55%")
    XCTAssertEqual(top[1].label, "WindowServer 40%")
  }

  func testHeatTooltipNamesTheCulprits() {
    let tip = MemoryFormat.heatTooltip(
      cpu: 0.78, thermal: .serious,
      busiest: [BusyProcess(name: "node", cpu: 180, count: 3)])
    XCTAssertTrue(tip.contains("Thermal state: Hot — macOS is slowing the CPU"))
    XCTAssertTrue(tip.contains("CPU 78%"))
    XCTAssertTrue(tip.contains("node ×3 180%"))
  }
}
