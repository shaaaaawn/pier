import AppKit
import SwiftUI

extension Notification.Name {
  /// Posted by the panel's gear button and ⌘, — the menu bar controller opens
  /// Settings and closes the panel.
  static let pierOpenSettings = Notification.Name("pierOpenSettings")
}

/// Pier's Settings window: a plain titled window hosting `SettingsView`.
@MainActor
final class SettingsWindow {
  static let shared = SettingsWindow()
  private var window: NSWindow?

  func show(onHiddenPortsChange: @escaping () -> Void) {
    if window == nil {
      let hosting = NSHostingView(rootView: SettingsView(onHiddenPortsChange: onHiddenPortsChange))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 480),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "Pier Settings"
      window.contentView = hosting
      window.isReleasedWhenClosed = false
      window.setContentSize(hosting.fittingSize)
      window.center()
      self.window = window
    }
    // An accessory app has to ask to come forward; without it the window
    // opens behind whatever app is frontmost.
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}

struct SettingsView: View {
  static let width: CGFloat = 460
  var onHiddenPortsChange: () -> Void = {}
  /// Fixture hook: render a fixed state instead of reading the machine.
  var fixture: Fixture?

  struct Fixture {
    var login: LoginItem.State = .off
    var combo: KeyCombo? = .defaultCombo
    var hidden: Set<Int> = [5353, 7000]
    var devStops = true
    var watched: Set<Int> = [3000]
    var permission: Notifier.Permission = .allowed
  }

  @State private var login: LoginItem.State = .off
  @State private var loginError: String?
  @State private var combo: KeyCombo?
  @State private var shortcutFailure: String?
  @State private var hidden: Set<Int> = []
  @State private var newPorts = ""
  @State private var devStops = false
  @State private var watched: Set<Int> = []
  @State private var newWatched = ""
  @State private var permission: Notifier.Permission = .notAsked

  var body: some View {
    Form {
      Section {
        Toggle(isOn: loginBinding) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Open Pier at login")
            if let note = loginNote {
              Text(note).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if login == .needsApproval {
          Button("Open Login Items Settings…") { LoginItem.openSystemSettings() }
        }
      } header: {
        Text("General")
      }

      Section {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Open the panel")
            Text("Works from any app — and when the menu bar icon is hidden.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          ShortcutRecorder(combo: $combo) { newCombo in
            KeyCombo.save(newCombo)
            if fixture == nil {
              HotKeyCenter.shared.register(newCombo)
              shortcutFailure = HotKeyCenter.shared.failure
            }
          }
        }
        if let shortcutFailure {
          Label(shortcutFailure, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
        }
      } header: {
        Text("Keyboard shortcut")
      }

      Section {
        Toggle(isOn: devStopsBinding) {
          VStack(alignment: .leading, spacing: 2) {
            Text("When a dev server stops")
            Text("Not when you stop it from Pier.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("When a watched port starts or stops")
          if watched.isEmpty {
            Text("Right-click a port to watch it, or add one that isn't running yet.")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            PortTags(ports: watched.sorted(), help: "Stop watching") { port in
              watched.remove(port)
              saveWatched(removing: [port])
            }
          }
        }
        HStack {
          TextField("Watch ports", text: $newWatched, prompt: Text("Watch ports, e.g. 3000"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit(addWatched)
          Button("Watch", action: addWatched)
            .disabled(HiddenPorts.parse(newWatched).isEmpty)
        }
        if permission == .denied {
          HStack {
            Label("Notifications for Pier are off in System Settings", systemImage: "bell.slash")
              .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button("Open…") { Notifier.openSystemSettings() }
          }
        }
      } header: {
        Text("Notifications")
      } footer: {
        Text(
          "Pier looks every 5 seconds while the panel is open and every 30 while it's closed, so a notification can arrive up to half a minute late."
        )
        .font(.caption).foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Section {
        if hidden.isEmpty {
          Text("No hidden ports. Right-click a port in the list to hide it.")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          PortTags(ports: hidden.sorted()) { port in
            hidden.remove(port)
            saveHidden()
          }
        }
        HStack {
          TextField("Add ports", text: $newPorts, prompt: Text("Add ports, e.g. 5353, 7000"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit(addPorts)
          Button("Add", action: addPorts)
            .disabled(HiddenPorts.parse(newPorts).isEmpty)
        }
      } header: {
        Text("Hidden ports")
      } footer: {
        Text(
          "Hidden ports keep running. Pier leaves them out of the list, the counts and the event feed."
        )
        .font(.caption).foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .formStyle(.grouped)
    .frame(width: Self.width)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear(perform: load)
  }

  private var loginBinding: Binding<Bool> {
    Binding(
      get: { login == .on || login == .needsApproval },
      set: { on in
        guard fixture == nil else { return }
        loginError = LoginItem.set(on)
        login = LoginItem.current
      })
  }

  private var devStopsBinding: Binding<Bool> {
    Binding(
      get: { devStops },
      set: { on in
        devStops = on
        guard fixture == nil else { return }
        UserDefaults.standard.set(on, forKey: NotifyRules.devStopsKey)
        if on { Notifier.shared.requestPermission { permission = $0 } }
      })
  }

  private func addWatched() {
    let ports = HiddenPorts.parse(newWatched)
    guard !ports.isEmpty else { return }
    watched.formUnion(ports)
    newWatched = ""
    saveWatched()
    if fixture == nil { Notifier.shared.requestPermission { permission = $0 } }
  }

  /// Merges with what's stored: a right-click watch made while this window
  /// is open isn't in `watched`, and writing the stale set back would drop it.
  private func saveWatched(removing: Set<Int> = []) {
    guard fixture == nil else { return }
    watched = WatchedPorts.current().union(watched).subtracting(removing)
    WatchedPorts.set(watched)
  }

  private var loginNote: String? {
    if let loginError { return loginError }
    switch login {
    case .needsApproval: return "Waiting for approval in System Settings → General → Login Items."
    case .unavailable: return "macOS can't register this copy of Pier. Move it to Applications."
    case .on, .off: return nil
    }
  }

  private func load() {
    if let fixture {
      login = fixture.login
      combo = fixture.combo
      hidden = fixture.hidden
      devStops = fixture.devStops
      watched = fixture.watched
      permission = fixture.permission
      return
    }
    login = LoginItem.current
    combo = KeyCombo.saved()
    shortcutFailure = HotKeyCenter.shared.failure
    hidden = HiddenPorts.current()
    devStops = UserDefaults.standard.bool(forKey: NotifyRules.devStopsKey)
    watched = WatchedPorts.current()
    Notifier.shared.permission { permission = $0 }
  }

  private func addPorts() {
    let ports = HiddenPorts.parse(newPorts)
    guard !ports.isEmpty else { return }
    hidden.formUnion(ports)
    newPorts = ""
    saveHidden()
  }

  private func saveHidden() {
    guard fixture == nil else { return }
    HiddenPorts.set(hidden)
    onHiddenPortsChange()
  }
}

/// Removable port tags, wrapping onto as many rows as they need.
private struct PortTags: View {
  let ports: [Int]
  var help = "Show again"
  let remove: (Int) -> Void

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 74), spacing: 6, alignment: .leading)], spacing: 6
    ) {
      ForEach(ports, id: \.self) { port in
        HStack(spacing: 4) {
          Text(verbatim: ":\(port)")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
          Button {
            remove(port)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("\(help): :\(port)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.14), in: Capsule())
      }
    }
  }
}

/// Click, then press the shortcut. Esc cancels; Delete clears it.
struct ShortcutRecorder: View {
  @Binding var combo: KeyCombo?
  let onChange: (KeyCombo?) -> Void
  @State private var recording = false
  @State private var monitor: Any?

  var body: some View {
    HStack(spacing: 6) {
      Button {
        recording ? stop(restore: true) : start()
      } label: {
        Text(recording ? "Press a shortcut…" : (combo?.display ?? "Record Shortcut"))
          .font(.system(size: 12, weight: combo == nil ? .regular : .medium, design: .rounded))
          .frame(minWidth: 72)
      }
      .help(recording ? "Esc to cancel · Delete to clear" : "Click to record a new shortcut")
      if combo != nil, !recording {
        Button {
          combo = nil
          onChange(nil)
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear the shortcut")
      }
    }
    .onDisappear { stop(restore: true) }
  }

  private func start() {
    recording = true
    // The current shortcut would fire while you press it again to record.
    HotKeyCenter.shared.register(nil)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      switch Int(event.keyCode) {
      case 53:  // Esc
        stop(restore: true)
      case 51, 117:  // Delete, Forward Delete
        combo = nil
        onChange(nil)  // saves + registers nil
        stop(restore: false)
      default:
        guard
          let recorded = KeyCombo.from(
            keyCode: event.keyCode, flags: event.modifierFlags,
            characters: event.charactersIgnoringModifiers)
        else { return nil }  // needs ⌘, ⌃ or ⌥ — keep listening
        combo = recorded
        onChange(recorded)  // saves + registers the new combo
        stop(restore: false)
      }
      return nil
    }
  }

  /// `restore`: re-register the shortcut `start()` suspended. Leaving it off
  /// after a recorded/cleared combo — `onChange` already registered that one.
  /// Without it, closing Settings mid-recording left the shortcut dead.
  private func stop(restore: Bool) {
    let wasRecording = recording
    recording = false
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if restore, wasRecording { HotKeyCenter.shared.register(combo) }
  }
}

/// `--render-fixture-settings <dir>`: the Settings window, light and dark,
/// with a fixed state (a shortcut, two hidden ports).
enum SettingsFixture {
  @MainActor
  static func render(to dir: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let hosting = NSHostingView(rootView: SettingsView(fixture: .init()))
      hosting.appearance = NSAppearance(named: appearance)
      let size = hosting.fittingSize
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: appearance)
      window.contentView = hosting
      window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
      window.orderBack(nil)
      hosting.layoutSubtreeIfNeeded()
      let path = "\(dir)/settings-\(name).png"
      guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
      hosting.cacheDisplay(in: hosting.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      print("wrote \(path)")
    }
    exit(0)
  }
}
