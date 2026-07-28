import XCTest

@testable import Pier

final class PreviewURLTests: XCTestCase {
  private func entry(
    port: Int = 8080,
    proto: PortProtocol = .tcp,
    binds: [String]
  ) -> PortEntry {
    PortEntry(
      pid: 1234, port: port, proto: proto, processName: "node", user: "shawn",
      bindAddresses: binds, attribution: .none
    )
  }

  func testIPv4WildcardAndLoopbackBindsMapToIPv4Loopback() {
    for bind in ["*", "0.0.0.0", "127.0.0.1"] {
      XCTAssertEqual(
        entry(binds: [bind]).previewURL?.absoluteString,
        "http://127.0.0.1:8080",
        "bind \(bind) should map to 127.0.0.1"
      )
    }
  }

  func testIPv6OnlyBindsMapToIPv6Loopback() {
    // An ::1-only listener refuses IPv4 connections, so previewing it via
    // 127.0.0.1 fails with "Could not connect to the server".
    for bind in ["::", "::1", "[::]", "[::1]"] {
      XCTAssertEqual(
        entry(binds: [bind]).previewURL?.absoluteString,
        "http://[::1]:8080",
        "bind \(bind) should map to [::1]"
      )
    }
  }

  func testSpecificHostBindIsUsed() {
    XCTAssertEqual(
      entry(binds: ["192.168.1.5"]).previewURL?.absoluteString,
      "http://192.168.1.5:8080"
    )
  }

  func testPrefersLoopbackWhenMultipleBinds() {
    XCTAssertEqual(
      entry(binds: ["::1", "127.0.0.1"]).previewURL?.absoluteString,
      "http://127.0.0.1:8080"
    )
  }

  func testPortIsPreserved() {
    XCTAssertEqual(
      entry(port: 8931, binds: ["*"]).previewURL?.absoluteString,
      "http://127.0.0.1:8931"
    )
  }

  func testDisplayAddress() {
    XCTAssertEqual(entry(binds: ["*"]).previewDisplayAddress, "127.0.0.1:8080")
    XCTAssertEqual(entry(binds: ["::1"]).previewDisplayAddress, "[::1]:8080")
    XCTAssertNil(entry(proto: .udp, binds: ["*"]).previewDisplayAddress)
  }

  func testUdpAndBindlessEntriesHaveNoPreview() {
    XCTAssertNil(entry(proto: .udp, binds: ["*"]).previewURL)
    XCTAssertNil(entry(binds: []).previewURL)
  }
}
