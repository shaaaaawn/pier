# CodexBar practices, applied to Pier

Distilled from [steipete/CodexBar](https://github.com/steipete/CodexBar)
([README](https://github.com/steipete/CodexBar/blob/main/README.md),
[architecture.md](https://github.com/steipete/CodexBar/blob/main/docs/architecture.md),
[refresh-loop.md](https://github.com/steipete/CodexBar/blob/main/docs/refresh-loop.md),
[status.md](https://github.com/steipete/CodexBar/blob/main/docs/status.md))
and mapped onto Pier. Status: **[adopted]** = already true in Pier,
**[next]** = queued, **[future]** = noted, not scheduled, **[decided]** =
evaluated and deliberately declined.

Sections 1–10 come from CodexBar's own docs. Sections 11–17 come from a later
pass over its **source**, which contradicts the docs in one place worth knowing
up front: CodexBar does not use `MenuBarExtra` or a popover at all (§11).

## 1. Source/provider abstraction — [next]

CodexBar puts every data source (OAuth APIs, browser cookies, CLIs, local
JSONL logs, SQLite caches like Windsurf's) behind one provider protocol, each
with per-source graceful degradation — a failing source never takes down the
refresh cycle.

Pier's seed of this exists today, and has grown: `Attributor` combines
`ProcessTable`, command lines and `CmuxSnapshot`; Docker, Apple `container` and
cmux each have their **own state enum** (`EngineState`, `CmuxStatus`) with a
per-source reason surfaced in the UI, which is the "graceful degradation with an
explanation" half of this practice already in place. What's still missing is the
uniform protocol and the enable/disable toggles. Refactor
direction: define a `PortSource` protocol (`func snapshot() -> PartialResult`)
with implementations `LsofSource`, `PsSource`, `CmuxSource`, and later
`~/.claude` / `~/.codex` local files, Claude/Codex JSONL session logs, and
SQLite caches (Windsurf). `PortMonitor.refresh()` becomes "collect from all
enabled sources, tolerate individual failures, merge." Each source carries its
own availability check, mirroring how `PortMonitor.resolveCmux()` works now.

## 2. Adaptive refresh — [future]

CodexBar defaults to an Adaptive cadence: a pure policy function of
last-menu-open, coding activity, Low Power Mode, and thermal state, clamped to
2–30 min. The **agent-aware** variant inspects the process list to detect
active Codex/Claude sessions and speeds up polling while you work — and it
**asks for consent first**; declining silently returns to plain Adaptive, and
the activity timestamp is never persisted.

Pier's equivalent of "recent interaction" already exists (5s while the window
is open, 30s in background). The natural Pier extension: when any
harness-attributed process (claude/kimi/codex/…) is alive, poll faster (e.g.
10s) because ports churn during agent work; drop to 60s when none are. Privacy
note to keep: inspecting the process list (including command lines) is exactly
what CodexBar gates behind an explicit opt-in — if Pier ever reads command
lines beyond the current `ps ucomm` basename, add the same ask-first consent
and keep the result in memory only.

## 3. Privacy-first stance — [adopted] (partially)

CodexBar: reads only a small set of known locations, never crawls the disk,
stores no passwords, keeps config at `~/.config/codexbar/config.json` with
restrictive permissions, and documents every macOS permission prompt.

Pier today: no network, and the only disk writes are `UserDefaults` UI prefs
(panel size, scope chip, preview width). Bounded subprocess probes with timeouts:
`lsof` ×2, `ps` ×2, and optionally `cmux top`, `docker ps`, `container list`.

Two things have moved since this was written and are worth stating plainly:
Pier now reads **full command lines** (`ps -axo command=`) for harness
attribution and MCP detection — CodexBar gates exactly that behind consent, and
a command line can itself contain a secret. It is memory-only and never
persisted, but the tooltip and `--print-*` probes can display one; redaction of
secret-shaped arguments is unimplemented. And the cmux **socket password** is
read from cmux's own config, so it is passed to the child via
`CMUX_SOCKET_PASSWORD` rather than argv, since `ps` is world-readable. Still to do when config lands: `~/.config/pier/config.json`
with `0600` permissions, and a permissions doc explaining each prompt — for
Pier the likely one is **Files & Folders**, triggered not by scanning but by
launching helper CLIs (cmux) whose working directory macOS attributes to us.

## 4. Bundled CLI + JSON output — [future]

CodexBar ships a `codexbar` CLI; its JSON output powers SketchyBar/tmux/Zellij
widgets and Linux desktop integrations. This is the natural path for the cmux
widget idea: a `pier` CLI emitting exactly what the menu bar shows.

Sketch:

```sh
pier list --json        # [{port, proto, pid, process, binds, attribution{kind,label,group}}...]
pier list               # human table, grouped like the app
pier kill <port|pid> [--force]
pier watch --interval 5 # NDJSON stream for cmux sidebar / tmux status / SketchyBar
```

Implementation note: the parsing/attribution core (`LsofParser`,
`CmuxSnapshot`, `Attributor`, entry building) is already UI-free; a CLI target
would reuse it directly. A cmux sidebar widget could then run
`pier list --json` on its own cadence without Pier.app running.

## 5. Dynamic menu bar icon semantics — [next]

CodexBar's icon reflects state: dims on stale/error, overlays an incident
indicator. Pier's pier glyph is a template image on a real `NSStatusItem` (so
AppKit already inverts it for light/dark and tints it while the panel is open),
which makes the rest cheap:

- Dim (reduce alpha / secondary appearance) when the last refresh cycle failed
  or is older than 2× the current interval.
- Small dot overlay when a new *unattributed* listener appears (a dev server
  Pier can't explain — the thing you most likely want to know about).

## 6. macOS 26 menu-bar-icon-missing issue — [adopted]

CodexBar issues
[#805](https://github.com/steipete/CodexBar/issues/805) and
[#861](https://github.com/steipete/CodexBar/issues/861) document the status
item silently not appearing on macOS 26 while the process keeps running — the
windowless LSUIElement app gets App-Napped / auto-terminated and its status
item is dropped. This is the same gap idle-screens hit; the proven fix is its
`beginActivity` pattern:

```swift
ProcessInfo.processInfo.beginActivity(
  options: .userInitiatedAllowingIdleSystemSleep,
  reason: "Keep menu bar status item presented")
```

held for the app's lifetime in `applicationDidFinishLaunching`. **Done** —
`AppDelegate.keepAliveActivity` in `PierApp.swift`. Note the framing changed
since this was written: Pier no longer uses `MenuBarExtra` at all (multi-display
placement forced a move to `NSStatusItem` + `NSPanel`), but the App Nap problem
is a property of windowless LSUIElement apps, not of `MenuBarExtra`, so the
assertion is still required.

## 7. Launch at login via SMAppService — [next]

CodexBar uses `SMAppService.mainApp` with a Settings toggle. Pier: a "Launch at
login" checkbox in the footer or a small Settings pane, calling
`SMAppService.mainApp.register()` / `.unregister()`. No helper needed for a
menu-bar-only app.

## 8. Settings/config file with per-source toggles — [future]

CodexBar: Settings → Providers toggles each source independently. Pier
equivalent: toggles for cmux integration, harness detection, and refresh rates
(visible / background interval), persisted to
`~/.config/pier/config.json` (0600). Pairs with practice 1 — toggles only make
sense once sources are behind a protocol.

## 9. Sparkle updates + packaging docs — [future]

CodexBar ships Sparkle + documented packaging/release checklists. For Pier,
skip Sparkle for now: the packaging path is idle-screens' existing
build/notarize pipeline (same SPM → `.app` → codesign shape), which we already
mirror with `scripts/build-app.sh`. Revisit auto-update only if Pier is
distributed beyond this machine.

## 10. Docs-driven repo layout — [adopted]

CodexBar keeps architecture.md, refresh-loop.md, a releasing checklist, and
per-provider docs with frontmatter summaries. We've started the skeleton:
`docs/architecture.md` (the current pipeline map) and this file. Rule going
forward: when a subsystem grows a non-obvious decision (refresh policy,
sources, CLI), it gets a short doc here rather than tribal knowledge.

---

# Second pass: reading the source

The sections above were distilled from CodexBar's README and `docs/`. This pass
read the actual sources (~1,600 Swift files). Several practices only exist in
code, including three status-item failure modes Pier does not defend against.

## 11. It's an `NSMenu`, not a panel — and that answers our menu bar question — [decided: not adopting]

CodexBar has **no `NSPopover`, no `MenuBarExtra`**, and its only two `NSPanel`s
are click-through overlays (confetti, quota alerts). The entire UI is a real
`NSMenu` whose items carry `NSHostingView` subviews:

```swift
item.view = hosting          // StatusItemController+MenuCardItems.swift:155
final class MenuCardItemHostingView<Content: View>: NSHostingView<Content>, …
```

This is the direct answer to the menu-bar-hiding research: a menu holds a
menu-tracking session, so macOS keeps the bar revealed; Pier's borderless
`NSPanel` is an ordinary window, so the reveal ends when the pointer leaves the
top edge (see the fullscreen-space finding — Pier's panel sits on a Split View
display whose bar auto-hides by design).

**The cost is the finding.** Hosting SwiftUI in an `NSMenu` took CodexBar ~50
extension files and roughly half a megabyte of source:

| File | Size | What it exists to solve |
| --- | --- | --- |
| `StatusItemController+Menu.swift` | 75 KB | menu construction |
| `+Animation.swift` | 67 KB | icon/menu animation |
| `+SwitcherViews.swift` | 65 KB | hosted switcher UI |
| `+MenuViewportRestore.swift` | 30 KB | restoring scroll position across rebuilds |
| `+MenuTracking.swift` | 25 KB | tracking sessions |
| `+MenuCardHeightCache` / `+MenuWidthCache` / `+MenuCardRecycling` / `+MenuReconcile` / `+MenuSmartUpdate` | — | measuring and recycling hosted rows |

Pier's panel hosts a `WKWebView` preview, a resize grabber, a search field and a
live log tail — all things menus are hostile to. **Recommendation: keep the
`NSPanel`** and treat the hiding bar as cosmetic (stop the panel chasing it).
The evidence says the menu route costs a rewrite plus a permanent caching and
measurement burden, to fix one cosmetic issue.

## 12. Three status-item-invisibility repairs Pier lacks — [adopted]

Item 6 above covers *one* cause (App Nap dropping the item). CodexBar defends
against three more, each a separate file, and Pier has none of them:

1. **Stale "hidden" flag** — `MenuBarStatusItemDefaultsRepair`. macOS persists
   `NSStatusItem VisibleCC <autosaveName> = false`; once set, the item never
   appears again. Cleared **once**, guarded by a `hasRepaired…` key so a later
   deliberate hide by the user is respected.
2. **Corrupt saved position** — `MenuBarStatusItemPlacementPreflight`. macOS
   persists `NSStatusItem Preferred Position <autosaveName>`; if it's `<= 0`, or
   further right than the widest screen's `maxX` (plus 512pt slack), the item is
   placed off-screen. Cleared at launch before the item is created.
3. **System force-hiding** — `MenuBarStatusItemWindowProbe.isTahoeBlockedProxy`.
   On macOS 26, a hidden item shows up as a **Control Center**-owned window at
   `x ≈ 0`, `maxY <= 0`, outside every display's bounds. Detecting that is the
   difference between "my icon is missing" and "the system hid my icon".

All three are pure, testable functions over `UserDefaults` values or
`CGWindowList` records. Worth porting more or less verbatim — Pier already has
the `CGWindowListCopyWindowInfo` plumbing in `MenuBarVisibility.swift`.

## 13. Probes take their inputs as parameters — [adopted]

CodexBar's window probe is unit-testable because the world is an argument:

```swift
static func snapshots(matching names: Set<String>) -> [Snapshot]        // real
static func snapshots(matching names: Set<String>,
                      windowInfo: [[String: Any]],
                      displayBounds: [CGRect]) -> [Snapshot]            // testable
```

The thin wrapper calls the real window server; the tested one takes captured
records. Same idea as Pier's parse-captured-CLI-output rule, extended to the
window server — which is exactly the layer Pier currently can only reach with
live probes (`--print-menubar`, `--probe-anchor`). Pier's `MenuBarVisibility`
should take `barRects()` output as a parameter for the same reason.

Their evidence structs also conform to `CustomStringConvertible` with a single
dense line (`visible=…,button=…,window=…,width=18.0`), so the same value serves
the assertion and the diagnostic. Pier's probes print ad-hoc strings instead.

## 14. Settle delays beat continuous polling — [adopted, for the visibility watch]

Pier's menu bar follow loop polls every 0.5s for the panel's lifetime.
CodexBar reacts to screen-parameter changes and re-checks with **staged delays**
— `screenChangeCheckDelay = 750ms`, then `screenChangeFollowUpDelay = 2s` —
because status item placement settles asynchronously after a display change.
Event + two settle checks is strictly less work than a timer, and catches the
case a single immediate check misses.

## 15. Explain, deep-link, then stop nagging — [future]

When the watcher decides the item is system-blocked, CodexBar opens
`x-apple.systempreferences:com.apple.MenuBarSettings` and records
`tahoeAllowListGuidanceLastShownAt`, repeating at most every 24h
(`guidanceRepeatInterval`). The pattern — detect, explain, deep-link to the
exact settings pane, rate-limit — is the right shape for anything Pier can
detect but not fix. Immediate candidate: the notification-permission denial
(`--probe-notify`), where Pier currently just documents the failure.

## 16. Tooling gaps — [decide]

- **Tests:** CodexBar has 663 test files, **647 on swift-testing** (`import
  Testing`, `@Test`, `#expect`, backticked sentence names) against 5 on XCTest.
  Pier's 204 tests are all XCTest. Migration is optional; the naming convention
  (`@Test func \`flags visible item without attached window\`()`) is worth
  stealing regardless — it reads like the sentence the test is proving.
- **Lint:** they run `swiftformat` + `swiftlint --strict` with checked-in
  `.swiftformat` / `.swiftlint.yml`, and AGENTS.md requires `make check` before
  handoff. Pier claims "swift-format-compatible style" in CLAUDE.md but nothing
  enforces it — and none of the three tools is installed on this machine.
- **`@Observable`:** their agent rules mandate `@Observable` + `@Bindable` over
  `ObservableObject`/`@StateObject`. **Blocked for Pier**: `@Observable` needs
  macOS 14 and Pier targets `.macOS(.v13)`. Revisit only if the floor rises.

## 17. Agent-instruction conventions worth borrowing — [adopted]

Their `AGENTS.md` is 48 lines — a fraction of Pier's `CLAUDE.md`, because Pier's
carries a traps list that is the genuinely load-bearing part. Two rules there
that Pier's does not state explicitly:

- **Never validate against a stale binary.** They spell out the exact
  `pkill … || true; open -n …` incantation and require UI claims to be checked
  against a freshly built bundle. Pier does this in practice; it isn't written down.
- **Never run anything that can raise a Keychain prompt** — use parser tests,
  stubs and test stores instead. Pier's analogue is the cmux socket password:
  worth an explicit "probes must not trigger auth UI" rule.
