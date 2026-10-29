import AppKit
import SwiftUI

// Split out of PortListView.swift, which had grown to ~1,370 lines — a fifth of
// the app. Extensions of the same type rather than new View structs: the pieces
// share a lot of @State (the expanded row, the hovered row, the pending
// confirmation), and threading all of that through as bindings would trade one
// kind of complexity for a worse one.
//
// Swift only lets extensions see `private` members within the same file, so
// members crossed by this split are module-internal now. They stay unavailable
// outside the Pier module, which is the boundary that actually matters here.

// The start/stop feed — what appeared and vanished, and who did it.
extension PortListView {
  // MARK: - Event feed

  /// What started and stopped since Pier launched, newest first. The point is
  /// the *actor* column: "Claude Code stopped node · chrome-devtools-mcp ×3" is
  /// the answer to "what just killed my server?".
  var eventFeed: some View {
    Group {
      if monitor.events.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "bell.slash")
            .font(.system(size: 20))
            .foregroundStyle(.tertiary)
          Text("Nothing has started or stopped yet")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
          // Says the limit out loud rather than letting a missed short-lived
          // process look like a bug.
          Text("Pier polls every 5s while open, 30s when closed")
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(monitor.events) { event in
              eventRow(event)
              Divider().opacity(0.25).padding(.leading, 34)
            }
          }
        }
      }
    }
  }

  func eventRow(_ event: PierEvent) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: event.action.symbol)
        .font(.system(size: 11))
        .foregroundStyle(event.action == .started ? Color.green : Color.orange)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(event.subject.name)
          .font(.system(size: 11.5, weight: .medium))
          .lineLimit(1)
          .truncationMode(.middle)
        HStack(spacing: 4) {
          Text(event.selfInitiated ? "you" : event.actor.badgeLabel)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(
              (event.selfInitiated ? Color.accentColor : Color.secondary).opacity(0.15),
              in: Capsule())
          Text(event.action.verb)
            .font(.system(size: 9.5))
          if event.count > 1 {
            Text(verbatim: "×\(event.count)")
              .font(.system(size: 9.5, weight: .medium))
          }
          Text(event.subject.kindLabel)
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Text.relative(event.date, live: monitor.windowVisible)
        .font(.system(size: 9.5))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
  }
}
