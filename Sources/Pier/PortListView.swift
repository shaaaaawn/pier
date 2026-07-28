import AppKit
import SwiftUI

struct PortListView: View {
  /// Default panel size. The live size is user-resizable (see `PanelSize`);
  /// these are what fixture renders use so PNGs stay reproducible.
  static let panelWidth: CGFloat = PanelSize.defaultWidth
  static let panelHeight: CGFloat = PanelSize.defaultHeight

  /// Fixture hook: pre-expand this row's preview so a render can grade the
  /// expanded layout (the click itself is a plain row tap).
  var initialExpandedID: String? = nil

  @EnvironmentObject private var monitor: PortMonitor
  @State private var search = ""
  /// Scope chip + system visibility, remembered across launches.
  @AppStorage("listFilter") private var filterRaw = PierFilter.all.rawValue
  @AppStorage("hideSystem") private var hideSystem = false
  /// Row ordering, remembered across launches. Defaults to Activity so a live
  /// dev server is the first thing on screen.
  @AppStorage("portSort") private var sortRaw = PortSort.activity.rawValue
  /// Collapsed section titles (ports groups + activity kinds).
  @State private var collapsed: Set<String> = []
  /// Live panel width, so the preview's viewport math follows a resize.
  @AppStorage(PanelSize.widthKey) private var storedWidth = Double(PanelSize.defaultWidth)
  @AppStorage(PanelSize.heightKey) private var storedHeight = Double(PanelSize.defaultHeight)
  /// The one pending confirmation. Deliberately a single piece of state:
  /// stacking several `.alert(item:)` modifiers on one view means SwiftUI
  /// presents only one of them, which silently swallowed the force-kill
  /// prompt — a process that ignored SIGTERM then looked like "kill did
  /// nothing" with no way to escalate.
  @State private var pending: PendingConfirmation?
  @State private var copiedID: String?
  @State private var tooltips: [String: String] = [:]
  /// The one expanded row and what it's showing (nil = all collapsed).
  @State private var expanded: RowExpansion?

  init(
    initialExpandedID: String? = nil, initialMode: RowExpansion.Mode = .preview,
    initialShowEvents: Bool = false
  ) {
    self.initialExpandedID = initialExpandedID
    _expanded = State(
      initialValue: initialExpandedID.map { RowExpansion(id: $0, mode: initialMode) })
    _showEvents = State(initialValue: initialShowEvents)
  }
  /// Manually expanded clusters (search-filtered ones auto-expand).
  @State private var expandedClusters: Set<String> = []
  /// Row currently hovered — reveals its action buttons.
  @State private var hoveredRowID: String?
  /// Events view replaces the list — what started and stopped, and who did it.
  @State private var showEvents = false

  private var filter: PierFilter {
    PierFilter(rawValue: filterRaw) ?? .all
  }

  private var sort: PortSort {
    PortSort(rawValue: sortRaw) ?? .activity
  }

  /// Preview card width — tracks the live panel width (minus the preview's own
  /// horizontal padding) so the desktop-viewport zoom stays correct after a
  /// resize.
  private var previewCardWidth: CGFloat {
    CGFloat(storedWidth) - 24
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      if showEvents {
        Divider().opacity(0.5)
        eventFeed
      } else {
        searchField
        filterBar
        cmuxBanner
        Divider().opacity(0.5)
        content
      }
      Divider().opacity(0.5)
      footer
    }
    // Fills whatever the panel window is — the window owns the size so a
    // resize drag doesn't fight SwiftUI's idea of it.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(VisualEffectBackground())
    .overlay(alignment: .trailing) { resizeEdges }
    .overlay(alignment: .bottom) { resizeBottomEdge }
    .alert(item: $pending) { confirmation in
      switch confirmation {
      case .kill(let entry):
        return Alert(
          title: Text("Kill \(entry.processName)?"),
          message: Text(killMessage(entry)),
          primaryButton: .destructive(Text("Kill")) { kill(entry) },
          secondaryButton: .cancel()
        )
      case .forceKill(let entry):
        return Alert(
          title: Text("\(entry.processName) is still running"),
          message: Text(
            "pid \(entry.pid) ignored SIGTERM. SIGKILL cannot be caught — but if a "
              + "parent supervises it, it may respawn."),
          primaryButton: .destructive(Text("Force Kill (SIGKILL)")) {
            monitor.terminate(entry.pid, force: true)
          },
          secondaryButton: .cancel()
        )
      case .docker(let action, let reclaimable):
        var message = action.confirmMessage
        if action != .stop, let reclaimable {
          message += "\n\nDocker reports reclaimable: \(reclaimable)."
        }
        return Alert(
          title: Text(action.title.replacingOccurrences(of: "…", with: "?")),
          message: Text(message),
          primaryButton: .destructive(Text(action.destroysData ? "Delete Anyway" : "Run")) {
            monitor.run(action)
          },
          secondaryButton: .cancel()
        )
      case .apple(let action, let reclaimable):
        var message = action.confirmMessage
        if action != .stop, let reclaimable {
          message += "\n\ncontainer system df reports reclaimable: \(reclaimable)."
        }
        return Alert(
          title: Text(action.title.replacingOccurrences(of: "…", with: "?")),
          message: Text(message),
          primaryButton: .destructive(Text(action.destroysData ? "Delete Anyway" : "Run")) {
            monitor.run(action)
          },
          secondaryButton: .cancel()
        )
      case .stop(let entry):
        return Alert(
          title: Text(entry.kind == .mcp ? "Kill \(entry.name)?" : "Stop \(entry.name)?"),
          message: Text(stopMessage(entry)),
          primaryButton: .destructive(Text(entry.kind == .mcp ? "Kill" : "Stop")) {
            monitor.stop(entry)
          },
          secondaryButton: .cancel()
        )
      }
    }
  }

  /// Says how many ports go with the pid, so killing a clustered row is not a
  /// surprise.
  private func killMessage(_ entry: PortEntry) -> String {
    let ports = monitor.entries.filter { $0.pid == entry.pid }.map(\.port).sorted()
    let portList = ports.map(String.init).joined(separator: ", ")
    return ports.count > 1
      ? "Send SIGTERM to pid \(entry.pid), which holds \(ports.count) ports (\(portList))."
      : "Send SIGTERM to pid \(entry.pid) (port \(entry.port))."
  }

  private func stopMessage(_ entry: ActivityEntry) -> String {
    switch entry.kind {
    case .mcp:
      return entry.count > 1
        ? "Send SIGTERM to \(entry.count) processes."
        : "Send SIGTERM to pid \(entry.pids.first.map(String.init) ?? "?")."
    case .docker: return "Run docker stop \(entry.name)."
    case .apple: return "Run container stop \(entry.name)."
    }
  }

  // MARK: - Header / footer

  private var header: some View {
    HStack(spacing: 7) {
      if let image = Bundle.module.image(forResource: "menubar-icon") {
        // .template + foregroundStyle so the glyph follows the appearance
        // (dark on light, light on dark) instead of baking in one color.
        Image(nsImage: image)
          .renderingMode(.template)
          .resizable()
          .frame(width: 15, height: 15)
          .foregroundStyle(.primary)
          .opacity(0.85)
      }
      Text("Pier")
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      // The count has to describe what's actually on screen — "19 shown" over a
      // list of events is a port count in the wrong place.
      Text(
        showEvents
          ? "\(monitor.events.count) event\(monitor.events.count == 1 ? "" : "s")"
          : "\(visibleCount) shown"
      )
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .help(
        showEvents
          ? "Starts and stops seen since launch"
          : "\(monitor.entries.count) listening · \(monitor.activity.count) background")
      if !showEvents {
        Button {
          hideSystem.toggle()
        } label: {
          Image(systemName: hideSystem ? "eye.slash" : "eye")
            .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(hideSystem ? Color.accentColor : .secondary)
        .help(hideSystem ? "Show system ports" : "Hide system ports")
      }
      if !showEvents {
        sortMenu
      }
      Button {
        showEvents.toggle()
      } label: {
        Image(systemName: showEvents ? "bell.fill" : "bell")
          .font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .foregroundStyle(showEvents ? Color.accentColor : .secondary)
      .help(showEvents ? "Back to ports" : "Recent starts and stops")
      Button {
        monitor.refresh()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Refresh now")
    }
    .padding(.horizontal, 14)
    .padding(.top, 9)
    .padding(.bottom, 7)
  }

  private var visibleCount: Int {
    monitor.visibleCount(matching: search, filter: filter, hideSystem: hideSystem)
  }

  /// Sort control. Lives in the header, not the chip row: at the 340pt minimum
  /// panel width the five scope chips already fill that row exactly, and adding
  /// anything made their labels wrap ("Co/nta/ine/rs"). `--render-fixture-narrow`
  /// is the render that catches it.
  private var sortMenu: some View {
    Menu {
      ForEach(PortSort.allCases) { option in
        Button {
          sortRaw = option.rawValue
        } label: {
          Label(option.label, systemImage: option == sort ? "checkmark" : option.symbol)
        }
      }
    } label: {
      Image(systemName: "arrow.up.arrow.down")
        .font(.system(size: 11))
        .foregroundStyle(sort == .activity ? Color.secondary : Color.accentColor)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Sort: \(sort.label)")
  }

  /// Scope chips — one tap to narrow to web servers, ports, containers, or MCP.
  private var filterBar: some View {
    HStack(spacing: 5) {
      ForEach(PierFilter.allCases) { option in
        let selected = option == filter
        Button {
          filterRaw = option.rawValue
        } label: {
          HStack(spacing: 3.5) {
            Image(systemName: option.symbol)
              .font(.system(size: 9))
            Text(option.label)
              .font(.system(size: 10.5, weight: .medium))
              .lineLimit(1)
              .fixedSize()
          }
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(
            selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05),
            in: Capsule()
          )
          .foregroundStyle(selected ? Color.accentColor : .secondary)
          .overlay(
            Capsule().strokeBorder(
              selected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 0.5)
          )
        }
        .buttonStyle(.plain)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
  }

  /// Why workspace grouping isn't happening. Silence here used to be
  /// ambiguous: a blocked cmux socket looked exactly like no cmux at all.
  @ViewBuilder
  private var cmuxBanner: some View {
    if let hint = monitor.cmuxStatus.hint {
      HStack(spacing: 5) {
        Image(systemName: "rectangle.split.3x1")
          .font(.system(size: 9))
        Text(hint)
          .font(.system(size: 10.5))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
        Image(systemName: "questionmark.circle")
          .font(.system(size: 9))
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
      )
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
      .help(monitor.cmuxStatus.detail ?? hint)
    }
  }

  /// Apple `container` equivalents. Deliberately different from Docker's menu:
  /// there's no aggregate prune and no restart command, so each resource type
  /// is pruned on its own and no fake restart is offered.
  private var appleMenu: some View {
    Menu {
      Section("Services") {
        ForEach(AppleAction.lifecycle) { action in
          Button(action.title) { requestApple(action) }
        }
      }
      Section(monitor.appleReclaimable.map { "Reclaimable: \($0)" } ?? "Clean up") {
        ForEach(AppleAction.cleanup) { action in
          Button(action.title, role: action.destroysData ? .destructive : nil) {
            requestApple(action)
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Apple container services and cleanup")
  }

  private func requestApple(_ action: AppleAction) {
    if action.needsConfirmation {
      pending = .apple(action, reclaimable: monitor.appleReclaimable)
    } else {
      monitor.run(action)
    }
  }

  /// Engine + cleanup actions, hung off the Docker section header. Prunes are
  /// confirmed and labeled with what `docker system df` says is reclaimable, so
  /// it's an informed click rather than a hopeful one.
  private var dockerMenu: some View {
    Menu {
      Section("Engine") {
        ForEach(DockerAction.lifecycle) { action in
          Button(action.title) { requestDocker(action) }
        }
      }
      Section(monitor.dockerReclaimable.map { "Reclaimable: \($0)" } ?? "Clean up") {
        ForEach(DockerAction.pruning) { action in
          Button(action.title, role: action.destroysData ? .destructive : nil) {
            requestDocker(action)
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Docker engine and cleanup")
  }

  private func requestDocker(_ action: DockerAction) {
    if action.needsConfirmation {
      pending = .docker(action, reclaimable: monitor.dockerReclaimable)
    } else {
      monitor.run(action)
    }
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
      TextField("Filter ports, processes, harnesses…", text: $search)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
      if !search.isEmpty {
        Button {
          search = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
  }

  // MARK: - Event feed

  /// What started and stopped since Pier launched, newest first. The point is
  /// the *actor* column: "Claude Code stopped node · chrome-devtools-mcp ×3" is
  /// the answer to "what just killed my server?".
  private var eventFeed: some View {
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

  private func eventRow(_ event: PierEvent) -> some View {
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
      Text(event.date, style: .relative)
        .font(.system(size: 9.5))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Group {
        if let last = monitor.lastRefresh {
          Text("Updated ") + Text(last, style: .relative)
        } else {
          Text("Not refreshed yet")
        }
      }
      .font(.system(size: 10))
      .foregroundStyle(.tertiary)
      Spacer()
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
      .controlSize(.small)
      resizeGrabber
    }
    .padding(.leading, 14)
    .padding(.trailing, 8)
    .padding(.vertical, 7)
  }

  /// Corner grip: drag to resize both dimensions, double-click to reset.
  /// The visible glyph is SwiftUI; the drag itself is an AppKit handle so a
  /// resize doesn't rebuild the list on every tick (see `ResizeHandleView`).
  private var resizeGrabber: some View {
    Image(systemName: "line.diagonal")
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.tertiary)
      .rotationEffect(.degrees(90))
      .frame(width: 20, height: 20)
      .overlay(ResizeHandle(axes: .both, resetsOnDoubleClick: true))
      .help("Drag to resize · double-click to reset")
  }

  /// Thin drag strips along the right and bottom edges, so the panel resizes
  /// the way a window does instead of only from the corner grip.
  private var resizeEdges: some View {
    ResizeHandle(axes: .horizontalOnly).frame(width: 6)
  }

  private var resizeBottomEdge: some View {
    ResizeHandle(axes: .verticalOnly).frame(height: 6)
  }

  // MARK: - Content

  private var content: some View {
    let groups = monitor.groups(
      matching: search, filter: filter, hideSystem: hideSystem, sort: sort)
    let activityGroups = monitor.activityGroups(matching: search, filter: filter)
    return ScrollView {
      if groups.isEmpty && activityGroups.isEmpty {
        Text(search.isEmpty ? "No listening ports" : "No matches")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.top, 40)
      } else {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(
            Array(PierSection.ordered(ports: groups, activity: activityGroups).enumerated()),
            id: \.element.id
          ) { index, section in
            if index > 0 {
              Divider().opacity(0.4).padding(.vertical, 2)
            }
            switch section {
            case .ports(let group):
              groupHeader(group)
              if !collapsed.contains(group.id) {
                ForEach(group.rows) { row in
                  rowView(row, groupTitle: group.title)
                }
              }
            case .activity(let group):
              activityGroupHeader(group)
              if !collapsed.contains(group.id) {
                if group.entries.isEmpty, engineState(for: group.kind)?.isReady != false {
                  engineEmptyRow(group.kind)
                } else {
                  ForEach(group.entries) { entry in
                    activityRow(entry)
                  }
                }
              }
            }
          }
        }
        .animation(.easeInOut(duration: 0.15), value: expanded)
        .animation(.easeInOut(duration: 0.15), value: expandedClusters)
        .animation(.easeInOut(duration: 0.15), value: collapsed)
      }
    }
  }

  // MARK: - Background activity (docker / containers / MCP)

  private func activityGroupHeader(_ group: ActivityGroup) -> some View {
    // With the engine down we don't know the container count — "0" would be a
    // claim, and a wrong one. Drop the pill and say the state instead.
    let down = engineState(for: group.kind).map { !$0.isReady } ?? false
    return HStack(spacing: 0) {
      sectionHeader(
        id: group.id, count: down ? nil : group.entryCount, title: group.title,
        subtitle: down
          ? "not running"
          : (group.stoppedCount > 0
            ? "\(group.stoppedCount) stopped" : nil)
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
    }
  }

  /// Brand mark when one is bundled (Docker's whale), else the SF Symbol.
  @ViewBuilder
  private func activityIcon(_ kind: ActivityKind, size: CGFloat) -> some View {
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

  /// The engine behind a section, or nil for MCP (no engine to be up or down).
  private func engineState(for kind: ActivityKind) -> EngineState? {
    switch kind {
    case .docker: return monitor.dockerState
    case .apple: return monitor.appleState
    case .mcp: return nil
    }
  }

  /// Shown when a *running* engine simply has no containers — including stopped
  /// ones, since both engines are listed with `-a`/`--all`. The engine-down case
  /// is stated in the header instead, so it isn't said twice.
  @ViewBuilder
  private func engineEmptyRow(_ kind: ActivityKind) -> some View {
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

  private func activityRow(_ entry: ActivityEntry) -> some View {
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

  private func activitySubline(_ entry: ActivityEntry) -> some View {
    HStack(spacing: 5) {
      Text(entry.detail)
        .lineLimit(1)
        .truncationMode(.middle)
      if !entry.ports.isEmpty {
        Text(verbatim: "→ " + entry.ports.map(String.init).joined(separator: ", "))
          .font(.system(size: 10, design: .monospaced))
      }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }

  /// Same usage-then-actions swap as port rows. Containers have no host pid,
  /// so only MCP rows carry a sparkline.
  private func activityTrailing(_ entry: ActivityEntry) -> some View {
    ZStack(alignment: .trailing) {
      usageStrip(entry.usage, pid: entry.pids.first ?? -1)
        .opacity(hoveredRowID == entry.id ? 0 : 1)
      activityActions(entry)
    }
  }

  private func activityActions(_ entry: ActivityEntry) -> some View {
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
        .help(entry.kind == .mcp ? "Kill process" : "Stop container")
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

  private func groupHeader(_ group: PortGroup) -> some View {
    sectionHeader(id: group.id, count: group.entryCount, title: group.title) {
      groupHeaderIcon(group)
    }
  }

  /// Shared section header for port groups and activity sections — click to
  /// collapse, so a busy machine stays scannable.
  private func sectionHeader<Icon: View>(
    id: String, count: Int?, title: String, subtitle: String? = nil,
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
  private func groupHeaderIcon(_ group: PortGroup) -> some View {
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

  // MARK: - Rows

  private func rowView(_ row: PortRow, groupTitle: String) -> some View {
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

  private func isClusterExpanded(_ row: PortRow) -> Bool {
    row.autoExpanded || expandedClusters.contains(row.id)
  }

  private func toggleCluster(_ row: PortRow) {
    if expandedClusters.contains(row.id) {
      expandedClusters.remove(row.id)
    } else {
      expandedClusters.insert(row.id)
    }
  }

  private func singleRow(_ entry: PortEntry, groupTitle: String) -> some View {
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
        subline(entry, emphasized: extra == nil)
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
  }

  /// Anywhere on a row toggles its preview. UDP (and anything without a
  /// browsable URL) has nothing to show, so it stays inert rather than
  /// opening an empty card. The port button and trailing actions are child
  /// buttons and keep their own taps.
  private func togglePreview(_ entry: PortEntry) {
    guard entry.previewURL != nil else { return }
    toggle(entry.id, mode: .preview)
  }

  /// One row is expanded at a time; clicking the same mode again collapses it,
  /// clicking the other mode switches without a collapse in between.
  private func toggle(_ id: String, mode: RowExpansion.Mode) {
    if expanded?.id == id, expanded?.mode == mode {
      expanded = nil
    } else {
      expanded = RowExpansion(id: id, mode: mode)
    }
  }

  /// The drawer under a row: web preview or log tail.
  @ViewBuilder
  private func expansion(for entry: PortEntry) -> some View {
    if expanded?.id == entry.id {
      switch expanded?.mode {
      case .logs:
        LogPanelView(
          source: LogSource.resolve(port: entry),
          toolPath: monitor.toolPath(for: LogSource.resolve(port: entry)),
          cmuxPassword: CmuxAccess.socketPassword(),
          fixtureLines: monitor.isFixture ? FixtureData.logLines : nil)
      default:
        PortPreviewView(
          entry: entry, fixtureState: monitor.isFixture ? .loaded : nil,
          cardWidth: previewCardWidth)
      }
    }
  }

  private func clusterRow(_ row: PortRow, groupTitle: String) -> some View {
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
          subline(entry)
        } else {
          // No badge to stack above, so the count rides the process line
          // instead of floating alone on its own row.
          HStack(spacing: 5) {
            subline(entry, emphasized: true)
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
    .onHover { hovering in hover(row.id, hovering: hovering) }
  }

  private func subRow(_ entry: PortEntry) -> some View {
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
  }

  // MARK: - Row pieces

  /// Monospaced, right-aligned port in a fixed-width column; click copies
  /// `localhost:<port>` with brief checkmark feedback.
  private func portButton(_ entry: PortEntry) -> some View {
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

  private func isShowing(_ id: String, _ mode: RowExpansion.Mode) -> Bool {
    expanded?.id == id && expanded?.mode == mode
  }

  /// Kill for a clustered row — one pid, so it takes every port under it.
  private func clusterKillButton(_ entry: PortEntry, rowID: String) -> some View {
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
  private func logsButton(_ id: String, source: LogSource) -> some View {
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
  private func usageStrip(_ usage: Usage?, pid: Int32) -> some View {
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
  private func usageTint(_ cpu: Double) -> Color {
    if cpu >= 80 { return .orange }
    if cpu >= 15 { return .accentColor }
    return Color(nsColor: .tertiaryLabelColor)
  }

  /// "×N" pill for a clustered row's hidden children.
  private func countChip(_ count: Int) -> some View {
    Text(verbatim: "×\(count)")
      .font(.system(size: 9, weight: .medium, design: .rounded))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Color.secondary.opacity(0.15), in: Capsule())
      .foregroundStyle(.secondary)
  }

  /// `emphasized` promotes the process name to the row's primary line — used
  /// when the badge was dropped as redundant with the group header.
  private func subline(_ entry: PortEntry, emphasized: Bool = false) -> some View {
    HStack(spacing: 5) {
      // verbatim: Text() localizes interpolated Ints (grouping separators in pids)
      Text(verbatim: entry.processName)
        .font(.system(size: emphasized ? 12 : 11, weight: emphasized ? .medium : .regular))
        .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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
  private func trailingSlot(_ entry: PortEntry) -> some View {
    ZStack(alignment: .trailing) {
      usageStrip(entry.usage, pid: entry.pid)
        .opacity(hoveredRowID == entry.id ? 0 : 1)
      actionButtons(entry, rowID: entry.id)
    }
  }

  /// Hover-revealed actions in a stable-width trailing slot. Kill is the only
  /// red element — and only while its row is hovered.
  private func actionButtons(_ entry: PortEntry, rowID: String) -> some View {
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

  private func badge(_ attribution: Attribution, text: String? = nil) -> some View {
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
  private func badgeIcon(_ attribution: Attribution) -> some View {
    if let iconName = attribution.iconName,
      let image = HarnessIcons.image(named: iconName)
    {
      Image(nsImage: image)
        .resizable()
        .frame(width: 12, height: 12)
    } else if case .cmux = attribution {
      Image(systemName: "rectangle.split.3x1")
        .font(.system(size: 9))
    }
  }

  private func badgeColor(_ attribution: Attribution) -> Color {
    switch attribution {
    case .cmux: return .purple
    case .harness: return .teal
    case .system: return Color(nsColor: .tertiaryLabelColor)
    case .none: return .gray
    }
  }

  private func rowHighlight(_ id: String) -> some View {
    RoundedRectangle(cornerRadius: 6)
      .fill(Color.primary.opacity(hoveredRowID == id ? 0.06 : 0))
      .padding(.horizontal, 4)
  }

  private func hover(_ id: String, hovering: Bool) {
    if hovering {
      hoveredRowID = id
    } else if hoveredRowID == id {
      hoveredRowID = nil
    }
  }

  // MARK: - Actions

  private func loadTooltip(_ entry: PortEntry) {
    guard tooltips[entry.id] == nil else { return }
    monitor.commandLine(for: entry.pid) { command in
      tooltips[entry.id] = command
    }
  }

  private func openInBrowser(_ entry: PortEntry) {
    // NSWorkspace.open honors the user's default browser.
    if let url = entry.previewURL {
      NSWorkspace.shared.open(url)
    }
  }

  private func copyAddress(_ entry: PortEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("localhost:\(entry.port)", forType: .string)
    copiedID = entry.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
      if copiedID == entry.id { copiedID = nil }
    }
  }

  private func kill(_ entry: PortEntry) {
    monitor.terminate(entry.pid)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      if monitor.isAlive(entry.pid) {
        pending = .forceKill(entry)
      }
    }
  }
}

/// Which row is expanded, and what it's showing. One row at a time keeps the
/// list navigable and means at most one live tail / webview exists.
struct RowExpansion: Equatable {
  enum Mode: Equatable {
    case preview
    case logs
  }

  let id: String
  let mode: Mode
}

/// The single pending confirmation dialog (see `pending`).
enum PendingConfirmation: Identifiable {
  case kill(PortEntry)
  case forceKill(PortEntry)
  case stop(ActivityEntry)
  case docker(DockerAction, reclaimable: String?)
  case apple(AppleAction, reclaimable: String?)

  var id: String {
    switch self {
    case .kill(let entry): return "kill-\(entry.id)"
    case .forceKill(let entry): return "force-\(entry.id)"
    case .stop(let entry): return "stop-\(entry.id)"
    case .docker(let action, _): return "docker-\(action.rawValue)"
    case .apple(let action, _): return "apple-\(action.rawValue)"
    }
  }
}

/// Tiny bar-chart sparkline, newest bar at the right.
///
/// Drawn in a single `Canvas` rather than an `HStack` of `RoundedRectangle`s:
/// the stack version created ~28 subviews per row, and with a couple of dozen
/// visible rows that's several hundred views for SwiftUI to lay out on every
/// tick of a panel resize. One Canvas draws the same bars in one pass.
struct SparklineView: View {
  let heights: [CGFloat]
  var tint: Color = .accentColor
  var barWidth: CGFloat = 2
  var spacing: CGFloat = 1
  var height: CGFloat = 12

  private var totalWidth: CGFloat {
    CGFloat(Sparkline.bars) * barWidth + CGFloat(Sparkline.bars - 1) * spacing
  }

  var body: some View {
    Canvas(opaque: false, rendersAsynchronously: false) { context, size in
      let color = tint.opacity(0.85)
      // Right-aligned: a young series grows in from the right edge.
      for (offsetFromRight, fraction) in heights.reversed().enumerated() {
        let x =
          size.width
          - CGFloat(offsetFromRight + 1) * barWidth
          - CGFloat(offsetFromRight) * spacing
        let barHeight = max(1, fraction * size.height)
        context.fill(
          Path(CGRect(x: x, y: size.height - barHeight, width: barWidth, height: barHeight)),
          with: .color(color))
      }
    }
    .frame(width: totalWidth, height: height)
  }
}

/// Native vibrancy for the panel background.
struct VisualEffectBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Cached loader for harness brand icons bundled in Resources/icons/.
/// Note: SPM's `.process` flattens PNGs to the bundle root, so no
/// subdirectory is used in the lookup. A missing/unloadable icon returns
/// nil and the UI falls back to text.
enum HarnessIcons {
  private static var cache: [String: NSImage?] = [:]

  static func image(named name: String) -> NSImage? {
    if let cached = cache[name] { return cached }
    let image = Bundle.module
      .url(forResource: name, withExtension: "png")
      .flatMap { NSImage(contentsOf: $0) }
    cache[name] = image
    return image
  }
}
