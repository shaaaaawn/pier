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

  @EnvironmentObject var monitor: PortMonitor
  /// Held, deliberately not observed: `MemoryGlanceView` observes it, so a
  /// memory tick redraws the footer glance instead of this whole panel.
  @Environment(\.memoryMonitor) var memoryMonitor
  @State var search = ""
  /// Scope chip + system visibility, remembered across launches.
  @AppStorage("listFilter") var filterRaw = PierFilter.all.rawValue
  @AppStorage("hideSystem") var hideSystem = false
  /// Row ordering, remembered across launches. Defaults to Activity so a live
  /// dev server is the first thing on screen.
  @AppStorage("portSort") var sortRaw = PortSort.activity.rawValue
  /// Collapsed section titles (ports groups + activity kinds).
  @State var collapsed: Set<String> = []
  /// Live panel width, so the preview's viewport math follows a resize.
  @AppStorage(PanelSize.widthKey) var storedWidth = Double(PanelSize.defaultWidth)
  @AppStorage(PanelSize.heightKey) var storedHeight = Double(PanelSize.defaultHeight)
  /// The one pending confirmation. Deliberately a single piece of state:
  /// stacking several `.alert(item:)` modifiers on one view means SwiftUI
  /// presents only one of them, which silently swallowed the force-kill
  /// prompt — a process that ignored SIGTERM then looked like "kill did
  /// nothing" with no way to escalate.
  @State var pending: PendingConfirmation?
  @State var copiedID: String?
  @State var tooltips: [String: String] = [:]
  /// The one expanded row and what it's showing (nil = all collapsed).
  @State var expanded: RowExpansion?

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
  @State var expandedClusters: Set<String> = []
  /// Row currently hovered — reveals its action buttons.
  @State var hoveredRowID: String?
  /// Events view replaces the list — what started and stopped, and who did it.
  @State var showEvents = false

  var filter: PierFilter {
    PierFilter.stored(filterRaw)
  }

  var sort: PortSort {
    PortSort(rawValue: sortRaw) ?? .activity
  }

  /// Preview card width — tracks the live panel width (minus the preview's own
  /// horizontal padding) so the desktop-viewport zoom stays correct after a
  /// resize.
  var previewCardWidth: CGFloat {
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
        detachedBanner
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
            monitor.terminate(entry.pid, force: true, expectedStart: entry.startTime)
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
          title: Text("\(entry.kind.stopVerb) \(entry.name)?"),
          message: Text(stopMessage(entry)),
          primaryButton: .destructive(Text(entry.kind.stopVerb)) {
            monitor.stop(entry)
          },
          secondaryButton: .cancel()
        )
      case .shutDownSimulators(let count):
        return Alert(
          title: Text(count == 1 ? "Shut down the simulator?" : "Shut down \(count) simulators?"),
          message: Text(
            "Runs xcrun simctl shutdown all. Apps running on them quit; the devices "
              + "and their data stay."),
          primaryButton: .destructive(Text("Shut Down All")) {
            monitor.shutDownAllSimulators()
          },
          secondaryButton: .cancel()
        )
      case .stopDetached(let entries):
        return Alert(
          title: Text(
            entries.count == 1
              ? "Stop the detached dev server?" : "Stop \(entries.count) detached dev servers?"),
          message: Text(Self.detachedSummary(entries)),
          primaryButton: .destructive(Text("Stop All")) {
            monitor.stopDetached(entries)
          },
          secondaryButton: .cancel()
        )
      }
    }
  }

  /// Says how many ports go with the pid, so killing a clustered row is not a
  /// surprise.
  func killMessage(_ entry: PortEntry) -> String {
    let ports = monitor.entries.filter { $0.pid == entry.pid }.map(\.port).sorted()
    let portList = ports.map(String.init).joined(separator: ", ")
    return ports.count > 1
      ? "Send SIGTERM to pid \(entry.pid), which holds \(ports.count) ports (\(portList))."
      : "Send SIGTERM to pid \(entry.pid) (port \(entry.port))."
  }

  func stopMessage(_ entry: ActivityEntry) -> String {
    switch entry.kind {
    case .mcp:
      return entry.count > 1
        ? "Send SIGTERM to \(entry.count) processes."
        : "Send SIGTERM to pid \(entry.pids.first.map(String.init) ?? "?")."
    case .docker: return "Run docker stop \(entry.name)."
    case .apple: return "Run container stop \(entry.name)."
    case .simulator:
      return "Run xcrun simctl shutdown for this \(entry.detail) device. Its apps quit; "
        + "the device and its data stay."
    }
  }

  var footer: some View {
    HStack(spacing: 8) {
      if let memoryMonitor {
        MemoryGlanceView(monitor: memoryMonitor)
        // Heat outranks disk: it changes minute to minute, disk doesn't.
        CPUGlanceView(monitor: memoryMonitor, busiest: monitor.busiest)
          .layoutPriority(-0.25)
        DiskGlanceView(monitor: memoryMonitor)
          .layoutPriority(-0.5)
      }
      // At the 340pt minimum the glance and "Updated" don't both fit. The
      // glance is the information; the refresh age is the part that yields —
      // and it yields *entirely*, because "Update…" says nothing.
      ViewThatFits(in: .horizontal) {
        Group {
          if let last = monitor.lastRefresh {
            Text("Updated ") + Text(last, style: .relative)
          } else {
            Text("Not refreshed yet")
          }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        Color.clear.frame(width: 0, height: 0)
      }
      .layoutPriority(-1)
      Spacer(minLength: 0)
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
  var resizeGrabber: some View {
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
  var resizeEdges: some View {
    ResizeHandle(axes: .horizontalOnly).frame(width: 6)
  }

  var resizeBottomEdge: some View {
    ResizeHandle(axes: .verticalOnly).frame(height: 6)
  }

  // MARK: - Content

  var content: some View {
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
  case shutDownSimulators(count: Int)
  case stopDetached([PortEntry])

  var id: String {
    switch self {
    case .kill(let entry): return "kill-\(entry.id)"
    case .forceKill(let entry): return "force-\(entry.id)"
    case .stop(let entry): return "stop-\(entry.id)"
    case .docker(let action, _): return "docker-\(action.rawValue)"
    case .apple(let action, _): return "apple-\(action.rawValue)"
    case .shutDownSimulators: return "simulators-shutdown-all"
    case .stopDetached: return "stop-detached"
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

  var totalWidth: CGFloat {
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

/// Icons for harnesses, terminals and engines, read from the apps installed
/// on this Mac. Pier bundles no third-party marks: an agent you have the app
/// for shows that app's icon, one you don't gets a monogram (`Monogram`).
///
/// Main-actor: only views read it, and the cache is unsynchronized. A miss is
/// cached too, so LaunchServices is asked once per set of IDs per launch.
@MainActor
enum AppIcons {
  static var cache: [[String]: NSImage?] = [:]
  /// Off for fixture renders, which must not depend on what's installed.
  static var lookupEnabled = true

  static func image(for bundleIDs: [String]) -> NSImage? {
    guard lookupEnabled, !bundleIDs.isEmpty else { return nil }
    if let cached = cache[bundleIDs] { return cached }
    let image = bundleIDs.lazy
      .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
      .first
      .map { url -> NSImage in
        // A 16pt drawing-handler image, so each draw picks the icon's best
        // representation for the scale instead of shrinking the 1024px one.
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
          icon.draw(in: rect)
          return true
        }
      }
    cache[bundleIDs] = image
    return image
  }
}

/// The stand-in for an agent with no app installed: its initial on a soft
/// rounded square, sized like the app icons it sits among.
struct Monogram: View {
  let label: String
  let size: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
      .fill(Color.primary.opacity(0.1))
      .overlay(
        Text(verbatim: String(label.prefix(1)).uppercased())
          .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
          .foregroundStyle(.secondary)
      )
      .frame(width: size, height: size)
  }
}
