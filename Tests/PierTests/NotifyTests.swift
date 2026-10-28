import XCTest

@testable import Pier

final class NotifyTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 1_000)

  private func event(
    _ action: PierEvent.Action, _ port: Int, _ process: String = "node",
    actor: Attribution = .harness("Claude Code"), dev: DevServer? = nil, mine: Bool = false
  ) -> PierEvent {
    var event = PierEvent(
      date: date, action: action, subject: .port(port, process: process), actor: actor)
    event.dev = dev
    event.selfInitiated = mine
    return event
  }

  private let angular = DevServer(framework: "Angular", project: "storefront")

  func testWatchedPortsNotifyBothWays() {
    let notes = NotifyRules.notes(
      for: [event(.started, 3000), event(.stopped, 3000), event(.stopped, 9229)],
      watched: [3000], devStops: false)
    XCTAssertEqual(notes.map(\.title), [":3000 started", ":3000 stopped"])
    XCTAssertEqual(notes.first?.body, "node · Claude Code")
  }

  func testDevStopsOnlyWhenOnAndOnlyStops() {
    let events = [event(.stopped, 4200, dev: angular), event(.started, 4200, dev: angular)]
    XCTAssertEqual(NotifyRules.notes(for: events, watched: [], devStops: false), [])
    let notes = NotifyRules.notes(for: events, watched: [], devStops: true)
    XCTAssertEqual(notes.map(\.title), ["Angular · storefront stopped"])
    XCTAssertEqual(notes.first?.body, ":4200 · Claude Code")
  }

  func testNothingPierDidItself() {
    let notes = NotifyRules.notes(
      for: [event(.stopped, 4200, dev: angular, mine: true), event(.stopped, 3000, mine: true)],
      watched: [3000], devStops: true)
    XCTAssertEqual(notes, [])
  }

  func testLocalAndSystemActorsAreLeftOut() {
    let notes = NotifyRules.notes(
      for: [event(.started, 3000, actor: .none), event(.started, 5353, "mDNS", actor: .system)],
      watched: [3000, 5353], devStops: false)
    XCTAssertEqual(notes.map(\.body), ["node", "mDNS"])
  }

  func testABurstBecomesOneSummary() {
    let events =
      (0..<5).map { event(.stopped, 4000 + $0, dev: angular) } + [
        event(.started, 3000)
      ]
    let notes = NotifyRules.notes(for: events, watched: [3000], devStops: true)
    XCTAssertEqual(notes.count, 1)
    XCTAssertEqual(notes.first?.title, "6 servers changed")
    XCTAssertEqual(notes.first?.body, "5 stopped · 1 started — open Pier to see which")
  }

  func testWatchToggleRoundTrips() {
    let defaults = UserDefaults(suiteName: "pier.notify.\(UUID().uuidString)")!
    XCTAssertTrue(WatchedPorts.toggle(3000, defaults))
    XCTAssertTrue(WatchedPorts.toggle(5173, defaults))
    XCTAssertEqual(WatchedPorts.current(defaults), [3000, 5173])
    XCTAssertFalse(WatchedPorts.toggle(3000, defaults))
    XCTAssertEqual(WatchedPorts.current(defaults), [5173])
  }

  func testDiffCarriesTheDevServer() {
    var entry = PortEntry(
      pid: 1, port: 4200, proto: .tcp, processName: "node", user: "dev",
      bindAddresses: ["127.0.0.1"], attribution: .none)
    entry.dev = angular
    let events = EventDiff.between(
      old: MonitorSnapshot(ports: [entry]), new: MonitorSnapshot(), at: date)
    XCTAssertEqual(events.first?.dev, angular)
  }

  @MainActor
  func testNoBundleMeansNoNotificationCenter() {
    // The test runner isn't an .app: handle() must return before touching
    // UNUserNotificationCenter, which would raise.
    XCTAssertFalse(Notifier.shared.isAvailable)
    let defaults = UserDefaults(suiteName: "pier.notify.\(UUID().uuidString)")!
    WatchedPorts.set([3000], defaults)
    Notifier.shared.handle([event(.started, 3000)], defaults: defaults)
  }
}
