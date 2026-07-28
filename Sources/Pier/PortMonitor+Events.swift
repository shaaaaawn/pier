import AppKit
import Combine
import Foundation

// Split out of PortMonitor.swift, which mixed three unrelated jobs in one
// 640-line file: probing the world, assembling rows, and acting on them.
//
// Stored properties stay on the class — Swift extensions can't declare them,
// and `@Published` needs storage — so only behaviour moved. Members crossed by
// the split are module-internal as a result; see PortListView's split for the
// same trade.

// Start/stop event recording: expectations, the diff, the unseen count.
extension PortMonitor {
  static let maxEvents = 200

  /// Record that Pier is about to cause an event, so the differ can label it.
  /// 60s of slack: `docker stop` can take a while, and a 30s poll may miss the
  /// window entirely when the panel is closed.
  func expect(_ action: PierEvent.Action, subject: PierEvent.Subject, ttl: TimeInterval = 60) {
    expectations.append((key: subject.key, action: action, expires: Date().addingTimeInterval(ttl)))
  }

  func markEventsSeen() {
    unseenEvents = 0
  }

  /// Diff this refresh against the last and record what changed.
  func recordEvents(ports: [PortEntry], activity: [ActivityEntry], now: Date) {
    let snapshot = MonitorSnapshot(ports: ports, activity: activity)
    defer { lastSnapshot = snapshot }
    guard !isFixture else { return }
    expectations.removeAll { $0.expires < now }
    var fresh = EventDiff.between(old: lastSnapshot, new: snapshot, at: now)
    guard !fresh.isEmpty else { return }
    for i in fresh.indices {
      if let match = expectations.firstIndex(where: {
        $0.key == fresh[i].subject.key && $0.action == fresh[i].action
      }) {
        fresh[i].selfInitiated = true
        expectations.remove(at: match)
      }
      PierLog.shared.log("event: \(fresh[i].summary)")
    }
    events = (fresh.reversed() + events).prefix(Self.maxEvents).map { $0 }
    unseenEvents += fresh.filter { !$0.selfInitiated }.count
  }
}
