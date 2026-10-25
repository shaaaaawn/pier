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

// Docker / Apple Containers / MCP sections.
extension PortListView {
  // MARK: - Background activity (docker / containers / MCP)

  func activityGroupHeader(_ group: ActivityGroup) -> some View {
    // With the engine down we don't know the container count — "0" would be a
    // claim, and a wrong one. Drop the pill and say the state instead.
    let down = engineState(for: group.kind).map { !$0.isReady } ?? false
    return HStack(spacing: 0) {
      sectionHeader(
        id: group.id, count: down ? nil : group.entryCount, title: group.title,
        subtitle: down
          ? engineFaultHeadline(for: group.kind)
          : (group.stoppedCount > 0
            ? "\(group.stoppedCount) stopped" : nil),
        subtitleHelp: down ? engineFaultDetail(for: group.kind) : nil
      ) {
        activityIcon(group.kind, size: 13)
      }
      if down {
        // The state is said once, in the header, with the action beside it —
        // a separate body row repeating "Docker isn't running" was the overlap.
        Button("Start") {
          if group.kind == .docker {
            monitor.run(DockerAction.start)
          } else {
            monitor.run(AppleAction.start)
          }
        }
        .controlSize(.mini)
        .padding(.top, 4)
        .help(
          group.kind == .docker
            ? "Runs: docker desktop start"
            : "Runs: container system start --enable-kernel-install")
      }
      if group.kind == .docker, monitor.dockerState != .cliMissing {
        dockerMenu
          .padding(.trailing, 12)
          .padding(.top, 5)
      }
      if group.kind == .apple, monitor.appleState != .cliMissing {
        appleMenu
          .padding(.trailing, 12)
          .padding(.top, 5)
      }
      if group.kind == .simulator, !group.entries.isEmpty {
        simulatorMenu(count: group.entries.count)
          .padding(.trailing, 12)
          .padding(.top, 5)
      }
    }
  }

  /// Brand mark when one is bundled (Docker's whale), else the SF Symbol.
  @ViewBuilder
  func activityIcon(_ kind: ActivityKind, size: CGFloat) -> some View {
    if let name = kind.iconName, let image = HarnessIcons.image(named: name) {
      Image(nsImage: image)
        .resizable()
        .frame(width: size, height: size)
    } else {
      Image(systemName: kind.symbol)
        .font(.system(size: size * 0.78))
        .foregroundStyle(.secondary)
    }
  }

  /// "not running" when nothing is listening, "not responding" when something
  /// answered and refused — Start only helps with the first.
  func engineFaultHeadline(for kind: ActivityKind) -> String {
    guard kind == .docker, let fault = monitor.dockerFault else { return "not running" }
    return fault.headline
  }

  func engineFaultDetail(for kind: ActivityKind) -> String? {
    guard kind == .docker else { return nil }
    return monitor.dockerFault?.detail
  }

  /// The engine behind a section, or nil for MCP (no engine to be up or down).
  func engineState(for kind: ActivityKind) -> EngineState? {
    switch kind {
    case .docker: return monitor.dockerState
    case .apple: return monitor.appleState
    case .mcp, .simulator: return nil
    }
  }

  /// Shown when a *running* engine simply has no containers — including stopped
  /// ones, since both engines are listed with `-a`/`--all`. The engine-down case
  /// is stated in the header instead, so it isn't said twice.
  @ViewBuilder
  func engineEmptyRow(_ kind: ActivityKind) -> some View {
    HStack(spacing: 6) {
      Spacer().frame(width: 54)
      Text("No containers")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Spacer(minLength: 4)
    }
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .padding(.vertical, 4)
  }

  func activityRow(_ entry: ActivityEntry) -> some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 8) {
        activityIcon(entry.kind, size: 15)
          .opacity(entry.isRunning ? 1 : 0.45)
          .frame(width: 54, alignment: .trailing)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            Text(entry.name)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(
                entry.isRunning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
              )
              .lineLimit(1)
              .truncationMode(.middle)
            if entry.count > 1 {
              Text(verbatim: "×\(entry.count)")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
            }
            if entry.kind == .mcp, entry.attribution != .none {
              badge(entry.attribution)
            }
          }
          activitySubline(entry)
        }
        Spacer(minLength: 4)
        activityTrailing(entry)
      }
      .padding(.leading, 12)
      .padding(.trailing, 10)
      .padding(.vertical, 4.5)
      .background(rowHighlight(entry.id))
      .contentShape(Rectangle())
      .onTapGesture {
        guard LogSource.resolve(activity: entry).isAvailable else { return }
        toggle(entry.id, mode: .logs)
      }
      .onHover { hovering in hover(entry.id, hovering: hovering) }
      .help(entry.detail)

      if isShowing(entry.id, .logs) {
        LogPanelView(
          source: LogSource.resolve(activity: entry),
          toolPath: monitor.toolPath(for: LogSource.resolve(activity: entry)),
          fixtureLines: monitor.isFixture ? FixtureData.logLines : nil)
      }
    }
  }

  func activitySubline(_ entry: ActivityEntry) -> some View {
    HStack(spacing: 5) {
      Text(entry.detail)
        .lineLimit(1)
        .truncationMode(.middle)
      if !entry.ports.isEmpty {
        Text(verbatim: "→ " + entry.ports.map(String.init).joined(separator: ", "))
          .font(.system(size: 10, design: .monospaced))
      }
      // Memory is why you'd shut a simulator down, so it gets the subline
      // rather than hiding in the usage tooltip like other rows.
      if entry.kind == .simulator, let usage = entry.usage {
        Text(verbatim: "· \(usage.memoryLabel)")
      }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }

  /// Same usage-then-actions swap as port rows. Containers have no host pid,
  /// so only MCP rows carry a sparkline.
  func activityTrailing(_ entry: ActivityEntry) -> some View {
    ZStack(alignment: .trailing) {
      usageStrip(entry.usage, pid: entry.pids.first ?? -1)
        .opacity(hoveredRowID == entry.id ? 0 : 1)
      activityActions(entry)
    }
  }

  func activityActions(_ entry: ActivityEntry) -> some View {
    // A stopped container's Start button is the row's whole point — don't hide
    // it behind hover the way the destructive actions are hidden.
    let visible = hoveredRowID == entry.id || !entry.isRunning
    return HStack(spacing: 10) {
      if let port = entry.ports.first,
        let url = URL(string: "http://127.0.0.1:\(port)")
      {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Image(systemName: "globe")
        }
        .help("Open localhost:\(port) in default browser")
      }
      logsButton(entry.id, source: LogSource.resolve(activity: entry))
      if entry.isRunning {
        Button {
          pending = .stop(entry)
        } label: {
          Image(systemName: "xmark.circle")
            .foregroundStyle(visible ? Color.red : Color.secondary)
        }
        .help(
          entry.kind == .mcp
            ? "Kill process"
            : entry.kind == .simulator ? "Shut down simulator" : "Stop container")
      } else {
        // A stopped container's useful action is the opposite one.
        Button {
          monitor.start(entry)
        } label: {
          Image(systemName: "play.circle.fill")
            .foregroundStyle(Color.accentColor)
        }
        .help("Start \(entry.name)")
      }
    }
    .font(.system(size: 12))
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
    .frame(width: entry.ports.isEmpty ? 44 : 66, alignment: .trailing)
  }

  func groupHeader(_ group: PortGroup) -> some View {
    sectionHeader(id: group.id, count: group.entryCount, title: group.title) {
      groupHeaderIcon(group)
    }
  }

  /// Shared section header for port groups and activity sections — click to
  /// collapse, so a busy machine stays scannable.
  func sectionHeader<Icon: View>(
    id: String, count: Int?, title: String, subtitle: String? = nil,
    subtitleHelp: String? = nil,
    @ViewBuilder icon: () -> Icon
  ) -> some View {
    let isCollapsed = collapsed.contains(id)
    return HStack(spacing: 5) {
      Image(systemName: "chevron.down")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(.tertiary)
        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
      icon()
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      if let count {
        Text(verbatim: "\(count)")
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Color.secondary.opacity(0.15), in: Capsule())
          .foregroundStyle(.secondary)
      }
      if let subtitle {
        Text(subtitle)
          .font(.system(size: 9.5))
          .foregroundStyle(.tertiary)
          // The engine's own words. Too long for the row, but the difference
          // between "start it" and "it's broken, here's why".
          .help(subtitleHelp ?? "")
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.top, 7)
    .padding(.bottom, 2)
    .contentShape(Rectangle())
    .onTapGesture {
      if isCollapsed { collapsed.remove(id) } else { collapsed.insert(id) }
    }
    .help(isCollapsed ? "Expand \(title)" : "Collapse \(title)")
  }

  @ViewBuilder
  func groupHeaderIcon(_ group: PortGroup) -> some View {
    if group.title.hasPrefix("cmux · ") {
      Image(systemName: "rectangle.split.3x1")
        .font(.system(size: 9))
    } else if let iconName = Attributor.iconName(forHarnessLabel: group.title),
      let image = HarnessIcons.image(named: iconName)
    {
      Image(nsImage: image)
        .resizable()
        .frame(width: 13, height: 13)
    }
  }
}
