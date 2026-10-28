import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a key plus Carbon modifier flags.
///
/// Registered with Carbon's `RegisterEventHotKey`, the API that needs **no**
/// permission. The alternative — a global `keyDown` monitor — needs Input
/// Monitoring and would raise a privacy prompt for one shortcut.
struct KeyCombo: Equatable, Sendable {
  /// Virtual key code (`kVK_ANSI_P` …).
  let keyCode: UInt32
  /// Carbon modifier mask (`cmdKey | optionKey` …).
  let modifiers: UInt32
  /// The key's printed character, captured when it was recorded ("P").
  let key: String

  /// ⌃⌥P. Rarely bound by other apps — unlike ⌥⌘P, which is Finder's path
  /// bar. Whatever is registered here is taken from every other app, so the
  /// default leans obscure and Settings can change or clear it.
  static let defaultCombo = KeyCombo(
    keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), key: "P")

  /// Apple's order: ⌃ ⌥ ⇧ ⌘.
  var display: String {
    var s = ""
    if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
    return s + key.uppercased()
  }

  static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.option) { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    if flags.contains(.shift) { m |= UInt32(shiftKey) }
    return m
  }

  /// A recorded key press, if it's usable as a global shortcut: at least one
  /// of ⌘ ⌃ ⌥ (Shift alone would steal a capital letter from every app).
  static func from(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> KeyCombo?
  {
    let modifiers = carbonModifiers(flags)
    guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0,
      let key = characters?.trimmingCharacters(in: .whitespaces), !key.isEmpty
    else { return nil }
    return KeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers, key: key.uppercased())
  }

  // MARK: - Storage ("35,6144,P"; "" = cleared, absent = default)

  static let defaultsKey = "openPanelShortcut"

  var stored: String { "\(keyCode),\(modifiers),\(key)" }

  init(keyCode: UInt32, modifiers: UInt32, key: String) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.key = key
  }

  init?(stored: String) {
    let parts = stored.split(separator: ",", maxSplits: 2).map(String.init)
    guard parts.count == 3, let code = UInt32(parts[0]), let mods = UInt32(parts[1]),
      !parts[2].isEmpty
    else { return nil }
    self.init(keyCode: code, modifiers: mods, key: parts[2])
  }

  /// The saved shortcut: the default until the user changes it, nil once they
  /// clear it.
  static func saved(_ defaults: UserDefaults = .standard) -> KeyCombo? {
    guard let value = defaults.string(forKey: defaultsKey) else { return defaultCombo }
    return KeyCombo(stored: value)
  }

  static func save(_ combo: KeyCombo?, _ defaults: UserDefaults = .standard) {
    defaults.set(combo?.stored ?? "", forKey: defaultsKey)
  }
}

/// Owns the one registered shortcut. Main-actor: Carbon delivers hot-key
/// events on the main thread, and Settings changes it from there.
@MainActor
final class HotKeyCenter {
  static let shared = HotKeyCenter()

  /// What pressing the shortcut does (the menu bar controller toggles the panel).
  var onPress: (() -> Void)?
  /// Why the current shortcut isn't active — another app owns the combination.
  private(set) var failure: String?

  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?

  /// Register `combo`, replacing any previous one. nil clears it. Returns false
  /// when macOS refuses — usually because another app already holds it.
  @discardableResult
  func register(_ combo: KeyCombo?) -> Bool {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = nil
    failure = nil
    guard let combo else { return true }
    installHandlerOnce()
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x5049_4552), id: 1)  // "PIER"
    let status = RegisterEventHotKey(
      combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let ref else {
      failure = "\(combo.display) is already used by another app — pick another shortcut"
      PierLog.shared.log("shortcut \(combo.display) not registered (status \(status))")
      return false
    }
    hotKey = ref
    return true
  }

  private func installHandlerOnce() {
    guard handler == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    // A C callback can't capture; it reaches the controller through the
    // shared instance. Carbon calls it on the main thread.
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, _ in
        MainActor.assumeIsolated { HotKeyCenter.shared.onPress?() }
        return noErr
      }, 1, &spec, nil, &handler)
  }
}
