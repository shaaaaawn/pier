import XCTest

@testable import Pier

final class TunnelTests: XCTestCase {
  func testProviderFromCommandLine() {
    XCTAssertEqual(
      Tunnels.provider(
        forCommand: "/opt/homebrew/bin/cloudflared tunnel --url http://localhost:3000"),
      .cloudflare)
    XCTAssertEqual(Tunnels.provider(forCommand: "cloudflared --url=localhost:8080"), .cloudflare)
    // The Access client isn't a tunnel out.
    XCTAssertNil(Tunnels.provider(forCommand: "cloudflared access tcp --hostname db.example.com"))
    XCTAssertEqual(Tunnels.provider(forCommand: "/usr/local/bin/ngrok http 3000"), .ngrok)
    XCTAssertNil(Tunnels.provider(forCommand: "node /Users/me/ngrok-tools/index.js"))
  }

  func testCloudflareTargets() {
    XCTAssertEqual(
      Tunnels.targets(
        provider: .cloudflare, command: "cloudflared tunnel --url http://localhost:3000"),
      [3000])
    XCTAssertEqual(
      Tunnels.targets(provider: .cloudflare, command: "cloudflared tunnel --url=127.0.0.1:8787"),
      [8787])
    XCTAssertEqual(
      Tunnels.targets(provider: .cloudflare, command: "cloudflared tunnel --url https://localhost"),
      [443])
    // Named tunnels route by config; the arguments don't say where.
    XCTAssertEqual(
      Tunnels.targets(provider: .cloudflare, command: "cloudflared tunnel run site"), [])
  }

  func testNgrokTargets() {
    XCTAssertEqual(Tunnels.targets(provider: .ngrok, command: "ngrok http 3000"), [3000])
    XCTAssertEqual(
      Tunnels.targets(
        provider: .ngrok, command: "ngrok http --url https://api.ngrok.app localhost:8080"),
      [8080])
    XCTAssertEqual(
      Tunnels.targets(provider: .ngrok, command: "ngrok http http://localhost:5173 --region us"),
      [5173])
    XCTAssertEqual(Tunnels.targets(provider: .ngrok, command: "ngrok tcp 22"), [22])
    XCTAssertEqual(Tunnels.targets(provider: .ngrok, command: "ngrok start --all"), [])
  }

  func testLocalPortRejectsOtherHosts() {
    XCTAssertEqual(Tunnels.localPort("4200"), 4200)
    XCTAssertEqual(Tunnels.localPort("[::1]:9000"), 9000)
    XCTAssertNil(Tunnels.localPort("https://api.ngrok.app"))
    XCTAssertNil(Tunnels.localPort("example.com:3000"))
    XCTAssertNil(Tunnels.localPort("70000"))
    XCTAssertNil(Tunnels.localPort("us"))
  }

  func testParsesTheirAPIs() {
    let quick = Data(#"{"hostname":"brave-otter-lake.trycloudflare.com"}"#.utf8)
    XCTAssertEqual(
      Tunnels.parseQuickTunnel(quick)?.absoluteString, "https://brave-otter-lake.trycloudflare.com")
    XCTAssertNil(Tunnels.parseQuickTunnel(Data(#"{"hostname":""}"#.utf8)))
    XCTAssertNil(Tunnels.parseQuickTunnel(Data("not json".utf8)))
    // The answer comes from a local process; only a bare hostname is believed.
    XCTAssertNil(Tunnels.parseQuickTunnel(Data(#"{"hostname":"evil.example@good.com"}"#.utf8)))
    XCTAssertNil(Tunnels.parseQuickTunnel(Data(#"{"hostname":"a.com?x=1#"}"#.utf8)))

    let ngrok = Data(
      #"""
      {"tunnels":[
        {"name":"command_line","public_url":"https://3f2a-81-2-69-160.ngrok-free.app","proto":"https",
         "config":{"addr":"http://localhost:3000","inspect":true}},
        {"name":"ssh","public_url":"tcp://0.tcp.ngrok.io:12345","proto":"tcp",
         "config":{"addr":"localhost:22","inspect":false}}
      ],"uri":"/api/tunnels"}
      """#.utf8)
    let parsed = Tunnels.parseNgrokTunnels(ngrok)
    XCTAssertEqual(parsed.map(\.target), [3000, 22])
    XCTAssertEqual(parsed.first?.publicURL.host, "3f2a-81-2-69-160.ngrok-free.app")
  }

  func testFindAndApplyMarkBothEnds() {
    func entry(_ pid: Int32, _ port: Int, _ name: String, binds: [String] = ["127.0.0.1"])
      -> PortEntry
    {
      PortEntry(
        pid: pid, port: port, proto: .tcp, processName: name, user: "dev",
        bindAddresses: binds, attribution: .none)
    }
    var entries = [
      entry(10, 3000, "node", binds: ["*"]),
      entry(20, 20241, "cloudflared"),
      entry(30, 4040, "ngrok"),
      entry(40, 8080, "python3"),
    ]
    let commands: [Int32: String] = [
      10: "node server.js",
      20: "/opt/homebrew/bin/cloudflared tunnel --url http://localhost:3000",
      30: "ngrok http 8080",
      40: "python3 -m http.server 8080",
    ]
    let found = Tunnels.find(entries: entries, commands: commands)
    XCTAssertEqual(
      found,
      [
        TunnelProcess(pid: 20, provider: .cloudflare, targets: [3000], apiPorts: [20241]),
        TunnelProcess(pid: 30, provider: .ngrok, targets: [8080], apiPorts: [4040]),
      ])

    let url = URL(string: "https://brave-otter-lake.trycloudflare.com")!
    Tunnels.apply(
      [
        ResolvedTunnel(pid: 20, provider: .cloudflare, target: 3000, publicURL: url),
        ResolvedTunnel(pid: 30, provider: .ngrok, target: 8080, publicURL: nil),
      ], to: &entries)
    XCTAssertEqual(entries[0].tunnel, TunnelLink(provider: .cloudflare, publicURL: url))
    XCTAssertEqual(entries[1].role, "Cloudflare Tunnel → :3000")
    XCTAssertNil(entries[1].tunnel)
    XCTAssertEqual(entries[2].role, "ngrok → :8080")
    XCTAssertEqual(entries[3].tunnel?.publicURL, nil)
    XCTAssertEqual(entries[3].tunnel?.help, "Public via ngrok — its address isn't known yet")
  }

  func testOnlyWebAddressesOpen() {
    XCTAssertNil(
      TunnelLink(provider: .ngrok, publicURL: URL(string: "tcp://0.tcp.ngrok.io:1")).browsableURL)
    XCTAssertNotNil(
      TunnelLink(provider: .ngrok, publicURL: URL(string: "https://a.ngrok.app")).browsableURL)
  }

  /// Nothing listening on the API port: the tunnel still shows, unnamed.
  func testResolverFallsBackToTheArguments() {
    let resolver = TunnelResolver()
    let resolved = resolver.resolve([
      TunnelProcess(pid: 99, provider: .cloudflare, targets: [3000], apiPorts: [1])
    ])
    XCTAssertEqual(
      resolved, [ResolvedTunnel(pid: 99, provider: .cloudflare, target: 3000, publicURL: nil)])
  }
}
