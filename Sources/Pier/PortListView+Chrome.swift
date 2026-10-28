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

// Header, search field, scope chips, sort menu, engine ⋯ menus, banners.
extension PortListView {
  // MARK: - Header / footer

  var header: some View {
    HStack(spacing: 7) {
      // .template + foregroundStyle so the glyph follows the appearance
      // (dark on light, light on dark) instead of baking in one color.
      Image(nsImage: PierGlyph.image())
        .renderingMode(.template)
        .resizable()
        .frame(width: 15, height: 15)
        .foregroundStyle(.primary)
        .opacity(0.85)
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
      Button {
        NotificationCenter.default.post(name: .pierOpenSettings, object: nil)
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Settings (⌘,)")
    }
    .padding(.horizontal, 14)
    .padding(.top, 9)
    .padding(.bottom, 7)
  }

  var visibleCount: Int {
    monitor.visibleCount(matching: search, filter: filter, hideSystem: hideSystem)
  }

  /// Sort control. Lives in the header, not the chip row: at the 340pt minimum
  /// panel width the five scope chips already fill that row exactly, and adding
  /// anything made their labels wrap ("Co/nta/ine/rs"). `--render-fixture-narrow`
  /// is the render that catches it.
  var sortMenu: some View {
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
  var filterBar: some View {
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
  var cmuxBanner: some View {
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

  /// Dev servers that outlived the session that started them — the stray
  /// servers agents leave behind. One line, one action, only when there are
  /// some, and only in scopes that list ports.
  @ViewBuilder
  var detachedBanner: some View {
    let detached = monitor.entries.filter(\.detached)
    if !detached.isEmpty, filter.showsPorts {
      let servers = Set(detached.map(\.pid)).count
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.circle")
          .symbolRenderingMode(.hierarchical)
          .font(.system(size: 10))
        ViewThatFits(in: .horizontal) {
          Text(
            servers == 1
              ? "A dev server outlived the session that started it"
              : "\(servers) dev servers outlived the session that started them")
          Text(servers == 1 ? "1 detached dev server" : "\(servers) detached dev servers")
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        Spacer(minLength: 4)
        Button("Stop All…") { pending = .stopDetached(detached) }
          .buttonStyle(.borderless)
          .font(.system(size: 10.5, weight: .semibold))
      }
      .foregroundStyle(Self.detachedTint)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(Self.detachedTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(Self.detachedTint.opacity(0.25), lineWidth: 0.5)
      )
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
      .help("Their agent or terminal has exited, but they're still listening.")
    }
  }

  /// One line per server, for the Stop All confirmation: what will be stopped,
  /// exactly.
  static func detachedSummary(_ entries: [PortEntry]) -> String {
    let lines = entries.sorted { $0.port < $1.port }.map { entry in
      ":\(entry.port)  \(entry.dev?.label ?? entry.processName)  (pid \(entry.pid))"
    }
    return "Sends SIGTERM to each, after checking it's still the same process:\n\n"
      + lines.joined(separator: "\n")
  }

  /// Apple `container` equivalents. Deliberately different from Docker's menu:
  /// there's no aggregate prune and no restart command, so each resource type
  /// is pruned on its own and no fake restart is offered.
  var appleMenu: some View {
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

  func simulatorMenu(count: Int) -> some View {
    Menu {
      Button("Shut Down All…", role: .destructive) {
        pending = .shutDownSimulators(count: count)
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Simulator actions")
  }

  func requestApple(_ action: AppleAction) {
    if action.needsConfirmation {
      pending = .apple(action, reclaimable: monitor.appleReclaimable)
    } else {
      monitor.run(action)
    }
  }

  /// Engine + cleanup actions, hung off the Docker section header. Prunes are
  /// confirmed and labeled with what `docker system df` says is reclaimable, so
  /// it's an informed click rather than a hopeful one.
  var dockerMenu: some View {
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

  func requestDocker(_ action: DockerAction) {
    if action.needsConfirmation {
      pending = .docker(action, reclaimable: monitor.dockerReclaimable)
    } else {
      monitor.run(action)
    }
  }

  var searchField: some View {
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
}
