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

// Port rows: clusters, single rows, expansion, and every row sub-piece.
extension PortListView {
  // MARK: - Rows

  func rowView(_ row: PortRow, groupTitle: String) -> some View {
    VStack(spacing: 0) {
      if row.isCluster {
        clusterRow(row, groupTitle: groupTitle)
        if isClusterExpanded(row) {
          ForEach(row.entries) { entry in
            subRow(entry)
            expansion(for: entry)
          }
        }
      } else {
        singleRow(row.primary, groupTitle: groupTitle)
        expansion(for: row.primary)
      }
    }
  }

  func isClusterExpanded(_ row: PortRow) -> Bool {
    row.autoExpanded || expandedClusters.contains(row.id)
  }

  func toggleCluster(_ row: PortRow) {
    if expandedClusters.contains(row.id) {
      expandedClusters.remove(row.id)
    } else {
      expandedClusters.insert(row.id)
    }
  }

  func singleRow(_ entry: PortEntry, groupTitle: String) -> some View {
    // The group header already names the attribution; only show a badge when
    // it adds something (a cmux surface), and promote the process line when it
    // doesn't — one tighter line instead of two saying the same thing.
    let extra = entry.attribution.rowBadge(inGroup: groupTitle)
    return HStack(alignment: .center, spacing: 8) {
      portButton(entry)
      VStack(alignment: .leading, spacing: 2) {
        if let extra {
          badge(entry.attribution, text: extra)
        }
        subline(entry, emphasized: extra == nil, groupTitle: groupTitle)
      }
      Spacer(minLength: 4)
      trailingSlot(entry)
    }
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .padding(.vertical, 4.5)
    .background(rowHighlight(entry.id))
    .contentShape(Rectangle())
    .onTapGesture { togglePreview(entry) }
    .onHover { hovering in
      hover(entry.id, hovering: hovering)
      if hovering { loadTooltip(entry) }
    }
    .help(tooltips[entry.id] ?? "")
    .contextMenu { portContextMenu(entry) }
  }

  /// Anywhere on a row toggles its preview. UDP (and anything without a
  /// browsable URL) has nothing to show, so it stays inert rather than
  /// opening an empty card. The port button and trailing actions are child
  /// buttons and keep their own taps.
  func togglePreview(_ entry: PortEntry) {
    guard entry.previewURL != nil else { return }
    toggle(entry.id, mode: .preview)
  }

  /// One row is expanded at a time; clicking the same mode again collapses it,
  /// clicking the other mode switches without a collapse in between.
  func toggle(_ id: String, mode: RowExpansion.Mode) {
    if expanded?.id == id, expanded?.mode == mode {
      expanded = nil
    } else {
      expanded = RowExpansion(id: id, mode: mode)
    }
  }

  /// The drawer under a row: web preview or log tail.
  @ViewBuilder
  func expansion(for entry: PortEntry) -> some View {
    if expanded?.id == entry.id {
      switch expanded?.mode {
      case .logs:
        LogPanelView(
          source: LogSource.resolve(port: entry),
          toolPath: monitor.toolPath(for: LogSource.resolve(port: entry)),
          cmuxPassword: monitor.cmuxPassword,
          fixtureLines: monitor.isFixture ? FixtureData.logLines : nil,
          active: monitor.windowVisible || monitor.isFixture)
      default:
        PortPreviewView(
          entry: entry,
          fixtureState: monitor.isFixture ? (PreviewIdleState.forcedState ?? .loaded) : nil,
          cardWidth: previewCardWidth,
          panelVisible: PreviewIdleState.forcedPanelVisible ?? monitor.windowVisible)
      }
    }
  }

  func clusterRow(_ row: PortRow, groupTitle: String) -> some View {
    let entry = row.primary
    let extra = entry.attribution.rowBadge(inGroup: groupTitle)
    return HStack(alignment: .center, spacing: 8) {
      portButton(entry)
      VStack(alignment: .leading, spacing: 2) {
        if let extra {
          HStack(spacing: 5) {
            badge(entry.attribution, text: extra)
            countChip(row.totalCount)
          }
          subline(entry, groupTitle: groupTitle)
        } else {
          // No badge to stack above, so the count rides the process line
          // instead of floating alone on its own row.
          HStack(spacing: 5) {
            subline(entry, emphasized: true, groupTitle: groupTitle)
            countChip(row.totalCount)
          }
        }
      }
      Spacer(minLength: 4)
      // A cluster is one pid holding several ports, so it gets its own kill —
      // otherwise the only way to stop it was to expand the cluster first and
      // kill a child row, which reads as "kill does nothing".
      ZStack(alignment: .trailing) {
        usageStrip(entry.usage, pid: entry.pid)
          .opacity(hoveredRowID == row.id ? 0 : 1)
        clusterKillButton(entry, rowID: row.id)
      }
    }
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .padding(.vertical, 4.5)
    .background(rowHighlight(row.id))
    .overlay(alignment: .leading) {
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isClusterExpanded(row) ? 90 : 0))
        .padding(.leading, 4)
    }
    .contentShape(Rectangle())
    .onTapGesture { toggleCluster(row) }
    .contextMenu { portContextMenu(row.primary) }
    .onHover { hovering in hover(row.id, hovering: hovering) }
  }

  func subRow(_ entry: PortEntry) -> some View {
    HStack(alignment: .center, spacing: 8) {
      portButton(entry)
      Text(entry.bindSummary)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 4)
      trailingSlot(entry)
    }
    .padding(.leading, 26)
    .padding(.trailing, 10)
    .padding(.vertical, 3)
    .background(rowHighlight(entry.id))
    .contentShape(Rectangle())
    .onTapGesture { togglePreview(entry) }
    .onHover { hovering in
      hover(entry.id, hovering: hovering)
      if hovering { loadTooltip(entry) }
    }
    .help(tooltips[entry.id] ?? "")
    .contextMenu { portContextMenu(entry) }
  }

  // MARK: - Row pieces

  /// Monospaced, right-aligned port in a fixed-width column; click copies
  /// `localhost:<port>` with brief checkmark feedback.
  func portButton(_ entry: PortEntry) -> some View {
    Button {
      copyAddress(entry)
    } label: {
      Group {
        if copiedID == entry.id {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.green)
        } else {
          Text(verbatim: "\(entry.port)")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
        }
      }
      .frame(width: 54, alignment: .trailing)
    }
    .buttonStyle(.plain)
    .help("Copy localhost:\(entry.port)")
  }

  func isShowing(_ id: String, _ mode: RowExpansion.Mode) -> Bool {
    expanded?.id == id && expanded?.mode == mode
  }

  /// Right-click: copy, open, hide. Hiding is the lightweight answer to "this
  /// port is always there and I don't care" — it keeps running, unlisted.
  @ViewBuilder
  func portContextMenu(_ entry: PortEntry) -> some View {
    if let url = entry.previewURL {
      Button("Open in Browser") { NSWorkspace.shared.open(url) }
    }
    Button("Copy localhost:\(String(entry.port))") { copyAddress(entry) }
    Divider()
    Button("Hide :\(String(entry.port))") {
      HiddenPorts.hide(entry.port)
      monitor.refresh()
    }
    Button("Hidden Ports…") {
      NotificationCenter.default.post(name: .pierOpenSettings, object: nil)
    }
  }

  /// Kill for a clustered row — one pid, so it takes every port under it.
  func clusterKillButton(_ entry: PortEntry, rowID: String) -> some View {
    let visible = hoveredRowID == rowID
    return Button {
      pending = .kill(entry)
    } label: {
      Image(systemName: "xmark.circle")
        .foregroundStyle(visible ? Color.red : Color.secondary)
    }
    .buttonStyle(.borderless)
    .font(.system(size: 12))
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
    .help("Kill pid \(entry.pid) (all its ports)")
  }

  /// Log-tail toggle. Always shown so the affordance is discoverable, dimmed
  /// when the row has no readable source — clicking still explains why rather
  /// than doing nothing.
  func logsButton(_ id: String, source: LogSource) -> some View {
    Button {
      toggle(id, mode: .logs)
    } label: {
      Image(systemName: isShowing(id, .logs) ? "text.alignleft" : "text.alignleft")
        .opacity(source.isAvailable ? 1 : 0.4)
    }
    .foregroundStyle(isShowing(id, .logs) ? Color.accentColor : .secondary)
    .help(source.isAvailable ? "Tail \(source.label)" : source.label)
  }

  /// CPU sparkline + percentage for a row, shown where the action buttons live
  /// and swapped out for them on hover — usage at a glance while scanning, and
  /// the controls only when you're aiming at them.
  @ViewBuilder
  func usageStrip(_ usage: Usage?, pid: Int32) -> some View {
    if let usage {
      HStack(spacing: 5) {
        SparklineView(
          heights: Sparkline.heights(monitor.history.series(for: pid)),
          tint: usageTint(usage.cpu))
        Text(usage.cpuLabel)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(width: 30, alignment: .trailing)
      }
      .help("CPU \(usage.cpuLabel) · memory \(usage.memoryLabel)")
    }
  }

  /// Quiet until it isn't: gray idle, accent when busy, orange when hot.
  func usageTint(_ cpu: Double) -> Color {
    if cpu >= 80 { return .orange }
    if cpu >= 15 { return .accentColor }
    return Color(nsColor: .tertiaryLabelColor)
  }

  /// "×N" pill for a clustered row's hidden children.
  func countChip(_ count: Int) -> some View {
    Text(verbatim: "×\(count)")
      .font(.system(size: 9, weight: .medium, design: .rounded))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Color.secondary.opacity(0.15), in: Capsule())
      .foregroundStyle(.secondary)
  }

  /// The row's name: a dev server's framework and project, else the process.
  static func rowName(_ entry: PortEntry, groupTitle: String?) -> String {
    guard let dev = entry.dev else { return entry.processName }
    return dev.project != nil && dev.project == groupTitle ? dev.framework : dev.label
  }

  /// `emphasized` promotes the process name to the row's primary line — used
  /// when the badge was dropped as redundant with the group header.
  ///
  /// A dev server is named for what it is — "Angular · shawns-www" — instead
  /// of its runtime ("node"), which is the same word for half the list. Under
  /// a project header (the Dev scope) the project is dropped as repetition.
  func subline(
    _ entry: PortEntry, emphasized: Bool = false, groupTitle: String? = nil
  ) -> some View {
    HStack(spacing: 5) {
      if entry.dev != nil {
        Image(systemName: "hammer")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .help("Dev server")
      }
      // verbatim: Text() localizes interpolated Ints (grouping separators in pids)
      Text(verbatim: Self.rowName(entry, groupTitle: groupTitle))
        .font(.system(size: emphasized ? 12 : 11, weight: emphasized ? .medium : .regular))
        .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        // The name is what the row is for; pid and bind address give way first.
        .layoutPriority(1)
      Text(verbatim: "· \(entry.pid)")
      if entry.proto == .udp {
        Text("UDP")
      }
      Text(entry.bindSummary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }

  /// Trailing slot: usage while idle, actions on hover. Both occupy the same
  /// space so rows never reflow as the pointer moves.
  func trailingSlot(_ entry: PortEntry) -> some View {
    ZStack(alignment: .trailing) {
      usageStrip(entry.usage, pid: entry.pid)
        .opacity(hoveredRowID == entry.id ? 0 : 1)
      actionButtons(entry, rowID: entry.id)
    }
  }

  /// Hover-revealed actions in a stable-width trailing slot. Kill is the only
  /// red element — and only while its row is hovered.
  func actionButtons(_ entry: PortEntry, rowID: String) -> some View {
    let visible = hoveredRowID == rowID
    return HStack(spacing: 10) {
      if entry.proto == .tcp {
        Button {
          toggle(entry.id, mode: .preview)
        } label: {
          Image(systemName: isShowing(entry.id, .preview) ? "eye.fill" : "eye")
        }
        .help(isShowing(entry.id, .preview) ? "Hide preview" : "Show preview")
        Button {
          openInBrowser(entry)
        } label: {
          Image(systemName: "globe")
        }
        .help("Open in default browser")
      }
      logsButton(entry.id, source: LogSource.resolve(port: entry))
      Button {
        pending = .kill(entry)
      } label: {
        Image(systemName: "xmark.circle")
          .foregroundStyle(visible ? Color.red : Color.secondary)
      }
      .help("Kill process")
    }
    .font(.system(size: 12))
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
    .frame(width: entry.proto == .tcp ? 88 : 44, alignment: .trailing)
  }

  func badge(_ attribution: Attribution, text: String? = nil) -> some View {
    HStack(spacing: 3) {
      badgeIcon(attribution)
      Text(text ?? attribution.smartBadgeLabel())
    }
    .font(.system(size: 10, weight: .medium))
    .padding(.horizontal, 6)
    .padding(.vertical, 1.5)
    .background(badgeColor(attribution).opacity(0.13), in: Capsule())
    .foregroundStyle(badgeColor(attribution))
    .lineLimit(1)
    .help(attribution.badgeLabel)
  }

  /// Brand icon at the leading edge of the badge; cmux-only attributions get
  /// a subtle SF Symbol, anything without an icon stays text-only.
  @ViewBuilder
  func badgeIcon(_ attribution: Attribution) -> some View {
    if let iconName = attribution.iconName,
      let image = HarnessIcons.image(named: iconName)
    {
      Image(nsImage: image)
        .resizable()
        .frame(width: 12, height: 12)
    } else if case .cmux = attribution {
      Image(systemName: "rectangle.split.3x1")
        .font(.system(size: 9))
    } else if case .terminal = attribution {
      Image(systemName: "terminal")
        .font(.system(size: 9))
    }
  }

  func badgeColor(_ attribution: Attribution) -> Color {
    switch attribution {
    case .cmux: return .purple
    case .harness, .terminal: return .teal
    case .system: return Color(nsColor: .tertiaryLabelColor)
    case .none: return .gray
    }
  }

  func rowHighlight(_ id: String) -> some View {
    RoundedRectangle(cornerRadius: 6)
      .fill(Color.primary.opacity(hoveredRowID == id ? 0.06 : 0))
      .padding(.horizontal, 4)
  }

  func hover(_ id: String, hovering: Bool) {
    if hovering {
      hoveredRowID = id
    } else if hoveredRowID == id {
      hoveredRowID = nil
    }
  }

  // MARK: - Actions

  func loadTooltip(_ entry: PortEntry) {
    guard tooltips[entry.id] == nil else { return }
    monitor.commandLine(for: entry.pid) { command in
      // Same masking as the log: hovering a row on a screen share shouldn't
      // show the `--api-key=…` its command line was started with.
      tooltips[entry.id] = PierLog.redact(command)
    }
  }

  func openInBrowser(_ entry: PortEntry) {
    // NSWorkspace.open honors the user's default browser.
    if let url = entry.previewURL {
      NSWorkspace.shared.open(url)
    }
  }

  func copyAddress(_ entry: PortEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("localhost:\(entry.port)", forType: .string)
    copiedID = entry.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
      if copiedID == entry.id { copiedID = nil }
    }
  }

  func kill(_ entry: PortEntry) {
    monitor.terminate(entry.pid, expectedStart: entry.startTime)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      if monitor.isAlive(entry.pid, expectedStart: entry.startTime) {
        pending = .forceKill(entry)
      }
    }
  }
}
