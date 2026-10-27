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

// Turning entries into the grouped, filtered, sorted sections the UI draws.
extension PortMonitor {
  /// Merge lsof records into entries, deduped by pid+port+protocol with
  /// distinct bind addresses collected.
  ///
  /// `sockets` is the combined `-iTCP -sTCP:LISTEN -iUDP` output, so TCP and UDP
  /// rows arrive interleaved. Entry order is therefore not meaningful — every
  /// grouping and sort downstream is a total order, which is what keeps the
  /// panel stable regardless.
  nonisolated static func buildEntries(sockets: String) -> [PortEntry] {
    var order: [String] = []
    var byKey: [String: PortEntry] = [:]
    let records = LsofParser.parse(sockets)
    for record in records {
      let key = "\(record.pid):\(record.port):\(record.proto.rawValue)"
      if var entry = byKey[key] {
        if !entry.bindAddresses.contains(record.bindAddress) {
          entry.bindAddresses.append(record.bindAddress)
          byKey[key] = entry
        }
      } else {
        byKey[key] = PortEntry(
          pid: record.pid, port: record.port, proto: record.proto,
          processName: record.command, user: record.user,
          bindAddresses: [record.bindAddress], attribution: .none
        )
        order.append(key)
      }
    }
    return order.compactMap { byKey[$0] }
  }

  /// Apply the scope chip + hide-system toggle before grouping. Pure so the
  /// chip semantics are unit-testable rather than buried in the view.
  nonisolated static func visibleEntries(
    _ entries: [PortEntry], filter: PierFilter, hideSystem: Bool
  ) -> [PortEntry] {
    guard filter.showsPorts else { return [] }
    return entries.filter { entry in
      if filter == .dev, entry.dev == nil { return false }
      return !(hideSystem && entry.attribution == .system)
    }
  }

  /// Filtered, grouped (attributed first, Other, then System), clustered by
  /// pid+attribution, ordered by `sort`. Pure/static for testability.
  ///
  /// `byProject` (the Dev scope) heads each section with the dev server's
  /// project instead of the harness that launched it — "what am I running"
  /// is answered by project; the harness stays visible as the row's badge.
  nonisolated static func buildGroups(
    entries: [PortEntry], matching query: String, sort: PortSort = .port,
    history: UsageHistory = UsageHistory(), byProject: Bool = false
  ) -> [PortGroup] {
    var groupOrder: [String] = []
    var rankByTitle: [String: Int] = [:]
    var bucketsByTitle: [String: [String: [PortEntry]]] = [:]
    var bucketOrderByTitle: [String: [String]] = [:]

    for entry in entries {
      let title = byProject ? (entry.dev?.project ?? "Other") : entry.attribution.groupTitle
      if bucketsByTitle[title] == nil {
        groupOrder.append(title)
        bucketsByTitle[title] = [:]
        bucketOrderByTitle[title] = []
      }
      rankByTitle[title] = byProject ? 0 : entry.attribution.groupRank
      let key = "\(entry.pid)|\(entry.attribution.badgeLabel)"
      if bucketsByTitle[title]![key] == nil {
        bucketOrderByTitle[title]!.append(key)
        bucketsByTitle[title]![key] = []
      }
      bucketsByTitle[title]![key]!.append(entry)
    }

    return
      groupOrder
      .map { title -> PortGroup in
        let rows: [PortRow] = bucketOrderByTitle[title]!.compactMap { key in
          let bucket = bucketsByTitle[title]![key]!
            .sorted { ActivityRank.areInOrder($0, $1, sort: sort, history: history) }
          let visible = query.isEmpty ? bucket : bucket.filter { $0.matches(query) }
          guard !visible.isEmpty else { return nil }
          return PortRow(
            entries: visible,
            totalCount: bucket.count,
            autoExpanded: !query.isEmpty && visible.count < bucket.count
          )
        }
        .sorted { ActivityRank.areInOrder($0.primary, $1.primary, sort: sort, history: history) }
        return PortGroup(
          title: title, rank: rankByTitle[title] ?? 1, rows: rows, isProject: byProject)
      }
      .filter { !$0.rows.isEmpty }
      .sorted { a, b in
        // Activity mode floats the section holding the most interesting
        // listener; otherwise the semantic order (agents, Other, System) holds.
        // System stays pinned last either way — it's never the answer to "what
        // am I running?", however busy it gets.
        if sort == .activity, a.rank != Attribution.system.groupRank,
          b.rank != Attribution.system.groupRank
        {
          let left =
            a.rows.map {
              ActivityRank.score($0.primary, series: history.series(for: $0.primary.pid))
            }.max() ?? 0
          let right =
            b.rows.map {
              ActivityRank.score($0.primary, series: history.series(for: $0.primary.pid))
            }.max() ?? 0
          if left != right { return left > right }
        }
        return (a.rank, a.title) < (b.rank, b.title)
      }
  }

  func groups(matching query: String) -> [PortGroup] {
    Self.buildGroups(entries: entries, matching: query)
  }

  func groups(
    matching query: String, filter: PierFilter, hideSystem: Bool, sort: PortSort = .activity
  ) -> [PortGroup] {
    Self.buildGroups(
      entries: Self.visibleEntries(entries, filter: filter, hideSystem: hideSystem),
      matching: query, sort: sort, history: history, byProject: filter == .dev)
  }

  /// Count shown in the header: what the current scope/search actually lists.
  func visibleCount(matching query: String, filter: PierFilter, hideSystem: Bool) -> Int {
    groups(matching: query, filter: filter, hideSystem: hideSystem)
      .reduce(0) { $0 + $1.entryCount }
      + activityGroups(matching: query, filter: filter).reduce(0) { $0 + $1.entryCount }
  }
}
