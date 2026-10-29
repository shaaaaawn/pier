import SwiftUI

extension Text {
  /// `Text(date, style: .relative)` that only ticks while someone can see it.
  ///
  /// A self-updating date is a timer inside the view graph, and `orderOut`
  /// doesn't stop it: with the panel closed it still re-resolves once a second,
  /// and each pass relayouts the whole hidden panel (AGENTS.md trap #21). A
  /// 61s `sample` of a closed panel spent ~1s in `NSHostingView.layout()`, one
  /// ~17ms pass a second, most of it resolving the footer's "Updated" age.
  ///
  /// Same fix as `IndeterminateBar`: drop the ticking view, don't flag it.
  /// When `live` is false this is a plain string in the same format, worked out
  /// when the view body runs — so a fixture render (no panel, never live)
  /// looks the same, and reopening the panel swaps the live text back in.
  static func relative(_ date: Date, live: Bool) -> Text {
    if live { return Text(date, style: .relative) }
    return Text(verbatim: RelativeAge.string(since: date))
  }
}

/// The static half of `Text.relative(_:live:)`: "12 sec", "2 min, 0 sec",
/// "2 yrs, 8 mths" — the shape `.relative` draws, two units at most.
enum RelativeAge {
  static func string(since date: Date, now: Date = Date()) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .short
    formatter.maximumUnitCount = 2
    formatter.allowedUnits = [.year, .month, .day, .hour, .minute, .second]
    formatter.zeroFormattingBehavior = .dropLeading
    return formatter.string(from: abs(now.timeIntervalSince(date))) ?? ""
  }
}
