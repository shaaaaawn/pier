import XCTest

@testable import Pier

/// SMC temperatures and fans. The pure parts are pinned with values read on
/// an M1 Max; the live read skips where there are no sensors (CI runs in VMs).
final class SMCTests: XCTestCase {
  /// The driver checks the struct size; a flattened `keyInfo` broke every call.
  func testKeyDataMatchesTheDriverLayout() {
    XCTAssertEqual(MemoryLayout<SMCKeyData>.stride, 80)
  }

  /// Read-only: the SMC's write command (6) is never sent.
  func testOnlyReadCommandsExist() {
    XCTAssertEqual(SMCCommand.all, [5, 8, 9])
    XCTAssertFalse(SMCCommand.all.contains(6))
  }

  func testCodec() {
    XCTAssertEqual(SMCCodec.fourCC("F0Ac"), 0x4630_4163)
    XCTAssertEqual(SMCCodec.string(SMCCodec.fourCC("Tp09")), "Tp09")
    // Fan 0's speed as the M1 Max reported it: little-endian float.
    XCTAssertEqual(Double(SMCCodec.float([9, 113, 44, 69]) ?? 0), 2759.07, accuracy: 0.01)
    XCTAssertNil(SMCCodec.float([1, 2, 3]))
  }

  /// Sensors are chosen by family and plausibility, never a per-model list.
  func testSensorSelection() {
    func key(_ name: String, _ type: String = "flt ") -> SMCKey {
      SMCKey(code: SMCCodec.fourCC(name), size: 4, type: SMCCodec.fourCC(type))
    }
    let readings: [(key: SMCKey, value: Float?)] = [
      (key("Tp01"), 70.8), (key("Tp05"), 72.9), (key("Te01"), 70.4),
      (key("Tg05"), 63.5),
      (key("Tp0Z"), 0),  // unpopulated sensor
      (key("TaLP"), 48.0),  // airflow, not CPU
      (key("TC0P", "sp78"), nil),  // Intel-style type: not decoded
      (key("F0Ac"), 2759), (key("F0Mn"), 1200), (key("F0Mx"), 5779), (key("F1Ac"), 2980),
    ]
    let sensors = SMCSensors.select(readings)
    XCTAssertEqual(sensors.cpu.map(\.name), ["Tp01", "Tp05", "Te01"])
    XCTAssertEqual(sensors.gpu.map(\.name), ["Tg05"])
    XCTAssertEqual(sensors.fans.map(\.current.name), ["F0Ac", "F1Ac"])
    XCTAssertEqual(sensors.fans[0].max?.name, "F0Mx")
    XCTAssertNil(sensors.fans[1].max)
  }

  func testRollingRange() {
    var range = RollingRange(window: 60)
    range.add(50, at: 0)
    XCTAssertNil(range.range, "one reading is a value, not a range")
    range.add(70, at: 30)
    XCTAssertEqual(range.range, 50...70)
    range.add(60, at: 80)  // the 50 at t=0 has aged out
    XCTAssertEqual(range.range, 60...70)
  }

  func testRangeLineClampsToItsScale() {
    XCTAssertEqual(RangeLine.position(67.5, in: 30...105), 0.5)
    XCTAssertEqual(RangeLine.position(120, in: 30...105), 1)
    XCTAssertEqual(RangeLine.position(-5, in: 0...1), 0)
  }

  func testTooltipStatesScalesAndWindow() {
    let tip = MemoryFormat.heatTooltip(
      cpu: 0.37, cpuRange: 0.1...0.9, thermal: .nominal,
      temperature: MemoryProbe.reading(78), temperatureRange: 61...93, busiest: [])
    XCTAssertTrue(tip.contains("Temperature 78°C"))
    XCTAssertTrue(tip.contains("Last 30 min: low 61°, high 93°"))
    XCTAssertTrue(tip.contains("Fans 2760 / 2980 rpm"))
    XCTAssertTrue(tip.contains("(100% = every core busy)"))
  }

  func testLiveReadingWhereSensorsExist() throws {
    guard let reading = SensorSampler().readNow() else {
      throw XCTSkip("no SMC CPU sensors on this machine (expected in CI VMs)")
    }
    XCTAssertTrue((10...125).contains(reading.cpuAverage))
    XCTAssertGreaterThanOrEqual(reading.cpuMax, reading.cpuAverage)
  }
}
