import XCTest

@testable import Pier

final class LsofParserTests: XCTestCase {
  let tcpFixture = """
    COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    ControlCe  470 dev   12u  IPv4 0xabc123      0t0  TCP 127.0.0.1:8888 (LISTEN)
    python3  73101 dev    3u  IPv4 0xdef456      0t0  TCP *:8931 (LISTEN)
    node     90220 dev   22u  IPv6 0x111         0t0  TCP [::1]:3000 (LISTEN)
    node     90220 dev   23u  IPv4 0x222         0t0  TCP 127.0.0.1:3000 (LISTEN)
    rapportd   555 dev    4u  IPv4 0x333         0t0  TCP *:49222
    """

  func testPlainTcpOutput() {
    let records = LsofParser.parse(tcpFixture, proto: .tcp)
    XCTAssertEqual(records.count, 5)

    let controlCenter = records[0]
    XCTAssertEqual(controlCenter.command, "ControlCe")
    XCTAssertEqual(controlCenter.pid, 470)
    XCTAssertEqual(controlCenter.user, "dev")
    XCTAssertEqual(controlCenter.proto, .tcp)
    XCTAssertEqual(controlCenter.bindAddress, "127.0.0.1")
    XCTAssertEqual(controlCenter.port, 8888)

    let python = records[1]
    XCTAssertEqual(python.bindAddress, "*")
    XCTAssertEqual(python.port, 8931)

    // Row without an explicit (LISTEN) state still parses.
    XCTAssertEqual(records[4].port, 49222)
  }

  func testIPv6Bind() {
    let records = LsofParser.parse(tcpFixture, proto: .tcp)
    let v6 = records.first { $0.port == 3000 && $0.bindAddress.contains(":") }
    XCTAssertEqual(v6?.bindAddress, "::1")
  }

  func testDuplicatePidRowsMerge() {
    let entries = PortMonitor.buildEntries(sockets: tcpFixture)
    XCTAssertEqual(entries.count, 4)  // 5 rows, node:3000 appears twice
    let node = entries.first { $0.port == 3000 }
    XCTAssertEqual(node?.pid, 90220)
    XCTAssertEqual(Set(node?.bindAddresses ?? []), ["::1", "127.0.0.1"])
  }

  func testUdpSkipsConnectedEndpoints() {
    let udpFixture = """
      COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
      mDNSRespo   123 _mdnsresponder 6u IPv4 0x1      0t0  UDP *:5353
      node      90220 dev   30u  IPv4 0x2          0t0  UDP 192.168.1.5:53122->8.8.8.8:53
      """
    let records = LsofParser.parse(udpFixture, proto: .udp)
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].port, 5353)
    XCTAssertEqual(records[0].proto, .udp)
  }

  func testSplitAddress() {
    XCTAssertEqual(LsofParser.splitAddress("127.0.0.1:8080")?.0, "127.0.0.1")
    XCTAssertEqual(LsofParser.splitAddress("[::1]:8080")?.0, "::1")
    XCTAssertEqual(LsofParser.splitAddress("*:5353")?.1, 5353)
    XCTAssertNil(LsofParser.splitAddress("*:*"))
    XCTAssertNil(LsofParser.splitAddress("noport"))
  }
}

/// `+c 0` stops lsof truncating COMMAND to 9 characters ("python3.1" for
/// python3.11), which put a wrong process name in every row — and in every
/// start/stop event. The wider column brings `\x20`-escaped spaces with it.
final class LsofCommandWidthTests: XCTestCase {
  func testUnescapesSpaceEscapes() {
    XCTAssertEqual(
      LsofParser.unescape(#"Cursor\x20Helper\x20(Plugin)"#), "Cursor Helper (Plugin)")
    XCTAssertEqual(LsofParser.unescape(#"Google\x20Drive"#), "Google Drive")
    XCTAssertEqual(LsofParser.unescape("python3.11"), "python3.11")
    // A malformed escape must survive rather than eat the rest of the name.
    XCTAssertEqual(LsofParser.unescape(#"weird\xZZname"#), #"weird\xZZname"#)
  }

  /// Verbatim `lsof +c 0` output from this machine.
  func testParsesFullWidthCommandRows() {
    let out = """
      COMMAND    PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
      python3.11 11565 dev 4u  IPv6 0xca7fb391e5f7663c      0t0  TCP *:8899 (LISTEN)
      Cursor\\x20Helper\\x20(Plugin) 51731 dev 30u IPv4 0x1 0t0 TCP 127.0.0.1:8231 (LISTEN)
      """
    let records = LsofParser.parse(out, proto: .tcp)
    XCTAssertEqual(records.map(\.command), ["python3.11", "Cursor Helper (Plugin)"])
    XCTAssertEqual(records.map(\.port), [8899, 8231])
  }
}
