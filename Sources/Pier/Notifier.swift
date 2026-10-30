import AppKit
import UserNotifications

/// Ports you've asked to hear about: a notification when one starts or stops.
/// Stored like `HiddenPorts` ("3000, 5173").
enum WatchedPorts {
  static let defaultsKey = "watchedPorts"

  static func current(_ defaults: UserDefaults = .standard) -> Set<Int> {
    HiddenPorts.parse(defaults.string(forKey: defaultsKey) ?? "")
  }

  static func set(_ ports: Set<Int>, _ defaults: UserDefaults = .standard) {
    defaults.set(HiddenPorts.format(ports), forKey: defaultsKey)
  }

  /// Watch or unwatch; returns whether the port is watched now.
  @discardableResult
  static func toggle(_ port: Int, _ defaults: UserDefaults = .standard) -> Bool {
    var ports = current(defaults)
    let watched = ports.insert(port).inserted
    if !watched { ports.remove(port) }
    set(ports, defaults)
    return watched
  }
}

/// Which events become system notifications. Pure, so the rules are tested
/// without a notification center.
enum NotifyRules {
  static let devStopsKey = "notifyDevStops"

  struct Note: Equatable {
    let id: String
    let title: String
    let body: String
  }

  /// Past this many in one refresh, one summary instead — a `docker compose
  /// down` or a dead agent session shouldn't stack a column of banners.
  static let maxSeparate = 3

  /// - A watched port starting or stopping.
  /// - With `devStops`, a dev server stopping.
  /// Never what Pier itself did: you know, you clicked Stop.
  static func notes(for events: [PierEvent], watched: Set<Int>, devStops: Bool) -> [Note] {
    let picked = events.filter { event in
      guard !event.selfInitiated, case .port(let port, _) = event.subject else { return false }
      return watched.contains(port) || (devStops && event.action == .stopped && event.dev != nil)
    }
    guard picked.count <= maxSeparate else {
      let stopped = picked.filter { $0.action == .stopped }.count
      let started = picked.count - stopped
      let parts = [
        stopped > 0 ? "\(stopped) stopped" : nil, started > 0 ? "\(started) started" : nil,
      ].compactMap { $0 }
      return [
        Note(
          id: "summary:\(picked.first?.id ?? "")",
          title: "\(picked.count) servers changed",
          body: parts.joined(separator: " · ") + " — open Pier to see which")
      ]
    }
    return picked.map(note)
  }

  /// "Angular · storefront stopped" over ":4200 · Claude Code"; a plain
  /// process reads ":3000 started" over "node · Codex".
  static func note(_ event: PierEvent) -> Note {
    guard case .port(let port, let process) = event.subject else {
      return Note(id: event.id, title: event.summary, body: "")
    }
    // "local" and "system" say nothing a notification needs.
    let actor: String? =
      switch event.actor {
      case .none, .system: nil
      default: event.actor.badgeLabel
      }
    if let dev = event.dev {
      return Note(
        id: event.id, title: "\(dev.label) \(event.action.verb)",
        body: [":\(port)", actor].compactMap { $0 }.joined(separator: " · "))
    }
    return Note(
      id: event.id, title: ":\(port) \(event.action.verb)",
      body: [process, actor].compactMap { $0 }.joined(separator: " · "))
  }
}

/// Posts `NotifyRules` notes through Notification Center, and opens the panel
/// when one is clicked.
///
/// Built on the event diff, so it inherits its limits: up to 30s late while
/// the panel is closed, and blind to anything that starts and stops between
/// two polls. Main-actor: `PortMonitor` records events there.
@MainActor
final class Notifier: NSObject {
  static let shared = Notifier()

  enum Permission: Equatable {
    case notAsked, allowed, denied
    /// No app bundle (`swift run`, tests): Notification Center can't be used.
    case unavailable
  }

  /// What clicking a notification does (the menu bar controller shows the panel).
  var onOpen: (() -> Void)?

  /// `UNUserNotificationCenter.current()` raises an exception outright
  /// without a real `.app` bundle, so everything checks this first.
  var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

  private var delegateInstalled = false

  func handle(_ events: [PierEvent], defaults: UserDefaults = .standard) {
    let notes = NotifyRules.notes(
      for: events, watched: WatchedPorts.current(defaults),
      devStops: defaults.bool(forKey: NotifyRules.devStopsKey))
    guard !notes.isEmpty, isAvailable else { return }
    installDelegate()
    for note in notes {
      let content = UNMutableNotificationContent()
      content.title = note.title
      content.body = note.body
      let request = UNNotificationRequest(identifier: note.id, content: content, trigger: nil)
      UNUserNotificationCenter.current().add(request) { error in
        if let error {
          PierLog.shared.log("notification not posted: \(error.localizedDescription)")
        }
      }
    }
  }

  func permission(_ completion: @escaping @MainActor (Permission) -> Void) {
    guard isAvailable else { return completion(.unavailable) }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let permission = Self.permission(settings.authorizationStatus)
      DispatchQueue.main.async { completion(permission) }
    }
  }

  /// Asks once; macOS answers from its own record after that. Only from a
  /// click — the prompt is a live action, never something a refresh triggers.
  func requestPermission(_ completion: @escaping @MainActor (Permission) -> Void = { _ in }) {
    guard isAvailable else { return completion(.unavailable) }
    installDelegate()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      granted, _ in
      DispatchQueue.main.async { completion(granted ? .allowed : .denied) }
    }
  }

  static func openSystemSettings() {
    let id = Bundle.main.bundleIdentifier ?? ""
    let url = URL(
      string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    if let url { NSWorkspace.shared.open(url) }
  }

  nonisolated static func permission(_ status: UNAuthorizationStatus) -> Permission {
    switch status {
    case .authorized, .provisional, .ephemeral: return .allowed
    case .denied: return .denied
    case .notDetermined: return .notAsked
    @unknown default: return .denied
    }
  }

  private func installDelegate() {
    guard !delegateInstalled else { return }
    delegateInstalled = true
    UNUserNotificationCenter.current().delegate = self
  }
}

extension Notifier: UNUserNotificationCenterDelegate {
  /// Show banners even while Pier is the active app — it usually is, right
  /// after you've used the panel.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    await MainActor.run { Notifier.shared.onOpen?() }
  }
}
