import AppKit

/// Makes fixture renders hermetic, and stops them vandalising your app.
///
/// Every UI preference the panel reads is `@AppStorage`, which means
/// `UserDefaults.standard` — the *same* domain the running app uses. That had
/// two consequences, both found by making the renders diffable:
///
/// 1. **Renders mutated live app state.** Seeding the scope chip wrote
///    `listFilter` into the real domain, so `make fixture` silently changed
///    which filter your panel had selected. Observed: a session of fixture
///    renders left the live filter on `web`.
/// 2. **Renders weren't reproducible.** A render that *doesn't* pin a value
///    inherits whatever the previous one left behind, so `--render-fixture`
///    produced different PNGs run to run depending on which fixture ran last.
///    That is fatal for a pixel-diff gate — the thing that catches refactor
///    regressions is worthless if it flakes on its own.
///
/// So a render now pins **every** key it could read and restores the previous
/// values on exit, via `atexit` so it survives the `exit()` calls the render
/// entry points make.
///
/// Main-actor: every render entry point is, and `saved` is unsynchronized.
@MainActor
enum FixtureDefaults {
  /// Every key the panel reads. Pinning a subset is what caused the flake, so
  /// adding a new `@AppStorage` key to the UI means adding it here too.
  static let keys: [String] = [
    "listFilter", "portSort", "hideSystem", "previewViewport",
    PanelSize.widthKey, PanelSize.heightKey,
  ]

  private static var saved: [String: Any?] = [:]
  private static var restoreRegistered = false

  /// Pin the UI to a known state. `scope` overrides the filter chip when a
  /// render wants a particular one.
  static func apply(scope: String? = nil, defaults: UserDefaults = .standard) {
    save(defaults)
    NSApp?.appearance = appearance()

    defaults.set(scope ?? PierFilter.all.rawValue, forKey: "listFilter")
    // Activity ordering depends on live CPU history; fixtures have a fixed
    // history, but pinning the mode keeps the render independent of whatever
    // the user last chose.
    defaults.set(PortSort.activity.rawValue, forKey: "portSort")
    defaults.set(false, forKey: "hideSystem")
    defaults.set(PreviewViewport.desktop.rawValue, forKey: "previewViewport")
    defaults.set(Double(PanelSize.defaultWidth), forKey: PanelSize.widthKey)
    defaults.set(Double(PanelSize.defaultHeight), forKey: PanelSize.heightKey)
  }

  /// `--appearance light|dark` (default dark). Pinned like every other input:
  /// left to the system setting, a render taken in light mode would differ
  /// from one taken in dark, and light mode would never get looked at.
  static func appearance(_ args: [String] = CommandLine.arguments) -> NSAppearance? {
    let value = args.firstIndex(of: "--appearance").flatMap { i in
      i + 1 < args.count ? args[i + 1] : nil
    }
    return NSAppearance(named: value == "light" ? .aqua : .darkAqua)
  }

  /// Put back exactly what was there — including *absence*, so a key the user
  /// never set doesn't get invented by running a render.
  static func restore(_ defaults: UserDefaults = .standard) {
    for (key, value) in saved {
      if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    saved = [:]
  }

  private static func save(_ defaults: UserDefaults) {
    guard saved.isEmpty else { return }
    for key in keys { saved[key] = defaults.object(forKey: key) }
    guard !restoreRegistered else { return }
    restoreRegistered = true
    // The render entry points are `-> Never` and call exit() directly, so a
    // deferred restore would never run.
    //
    // The handler runs on whichever thread calls exit(). Every render exits
    // from the main thread, but a C callback can't prove that to the compiler,
    // and `assumeIsolated` off-main would trap mid-exit — so check, and skip
    // rather than crash if a future caller exits from a background queue.
    atexit {
      guard Thread.isMainThread else { return }
      MainActor.assumeIsolated { FixtureDefaults.restore() }
    }
  }
}
