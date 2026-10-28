import ServiceManagement

/// "Open at login", via `SMAppService.mainApp` (macOS 13+).
///
/// The truth is macOS's, not ours: the toggle reads `status` every time instead
/// of storing a boolean, because the user can remove Pier in System Settings →
/// General → Login Items at any moment, and approval can be pending there.
enum LoginItem {
  enum State: Equatable {
    case on
    case off
    /// Registered, but the user must allow it in System Settings.
    case needsApproval
    /// macOS can't find this copy of the app to register (e.g. a moved build).
    case unavailable
  }

  static func state(_ status: SMAppService.Status) -> State {
    switch status {
    case .enabled: return .on
    case .requiresApproval: return .needsApproval
    case .notRegistered: return .off
    case .notFound: return .unavailable
    @unknown default: return .unavailable
    }
  }

  static var current: State { state(SMAppService.mainApp.status) }

  /// Turn it on or off; returns a message to show when macOS refuses.
  static func set(_ enabled: Bool) -> String? {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      PierLog.shared.log("open at login: \(enabled ? "on" : "off")")
      return nil
    } catch {
      PierLog.shared.log("open at login change failed")
      return error.localizedDescription
    }
  }

  static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
