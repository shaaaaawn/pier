# Pier architecture

Menu bar app (LSUIElement, no Dock icon) that lists listening ports, attributes
each to the agent harness / cmux session that spawned it, and manages the
container engines and MCP servers running alongside them. Plain SPM executable,
no Xcode project, no dependencies.

**Not `MenuBarExtra`.** The panel is an `NSStatusItem` plus a borderless
`NSPanel` whose frame is computed from the live status-button rect: **left-aligned**
to the item, like a menu bar menu, sliding inward when the item sits near a screen
edge.

With more than one display macOS installs a status-bar window per screen, and both
`MenuBarExtra` and `NSPopover(relativeTo:of:)` place the window on the primary one
— measured at x0 while the icon sat at x4766. See `PanelPlacement` and
`--probe-anchor`.

## Collection pipeline

One refresh cycle, on a background queue, every 5s while the panel is open and
30s in the background:

```
lsof -nP -iTCP -sTCP:LISTEN ─┐
lsof -nP -iUDP               ├─► LsofParser ─► [LsofRecord] ─► buildEntries
                             │                        (dedupe pid+port+proto,
ps -axo pid=,ppid=,%cpu=,    │                         merge bind addresses)
        rss=,ucomm=  ────────┼─► ProcessTable  ancestor chains + CPU/RSS
                             │
ps -axo pid=,user=,command= ─┼─► commands map   full command lines (shared by
                             │                  attribution AND MCP detection —
                             │                  one probe, two consumers)
cmux top --all --processes ──┤─► CmuxSnapshot   pid → surface → workspace
   --flat --format tsv       │   + CmuxStatus   (why it failed, if it did)
                             │
docker ps --format … ────────┼─► ActivityParser ─► Docker rows + EngineState
container list ──────────────┴─► ActivityParser ─► Apple rows  + EngineState
                                 (ps commands) ─► MCP rows, grouped by label
                                        │
                                        ▼
                              Attributor.attribute()
                    root or port <1024                  → .system
                    else walk chain, self first:
                      ucomm word-boundary match         → .harness
                      full command path (opt-in tokens) → .harness
                    else cmux surface hit               → .cmux(+harness)
                    else                                → .none
                                        │
                                        ▼
                    PortMonitor  @Published entries · activity · history
                                 cmuxStatus · dockerState · appleState
                                 dockerReclaimable · appleReclaimable
                                        │
                                        ▼
                    PierSection.ordered(ports:activity:)
                    attributed harness/cmux groups → Docker → Apple
                    Containers → MCP → Other → System
                                        │
                                        ▼
                    PortListView — clustered by pid+attribution, port-sorted,
                    search + scope chips, collapsible sections, CPU sparkline
                    per row, row actions, and two expansion drawers
                    (web preview / log tail)
```

Row badges are suppressed when they would repeat their section header
(`Attribution.rowBadge(inGroup:)`), which is why an attributed row is one line
while a cmux row keeps its surface name.

## Files

Pure and testable — parsers over captured real output:

- `LsofParser.swift` — lsof rows → `LsofRecord`.
- `CmuxSnapshot.swift` — `ProcessTable` (ps snapshot, ancestor chains, CPU/RSS)
  and `CmuxSnapshot` (cmux TSV → pid→surface→workspace, plus the surface **ref**
  the log panel needs).
- `Attributor.swift` — `harnessTable` (the extension point) + signal combining.
- `ActivityMonitor.swift` — `ActivityKind`/`ActivityEntry` and the Docker /
  Apple / MCP parsers, including which processes count as MCP servers.
- `DockerControl.swift` — `EngineState`, `DockerAction`, `docker system df`
  parsing, reclaimable summary.
- `AppleControl.swift` — the same for Apple's `container`, where the CLI differs
  (no aggregate prune, no restart, no force flags).
- `Usage.swift` — `Usage`, the `UsageHistory` ring buffer, `Sparkline` shaping.
- `LogTail.swift` — `LogSource` resolution (and why a source is unavailable) plus
  `LogText` chunk/line handling; `LogTailer` owns the live process.
- `CmuxAccess.swift` — cmux socket config (JSONC comment stripping), status
  classification, and the password-via-environment rule.
- `PanelSize.swift` / `PanelPlacement` (in `PierApp.swift`) — panel geometry.
- `Models.swift` — `PortEntry`, `Attribution`, `PortRow`, `PortGroup`,
  `PierSection`, `PierFilter`, `PreviewViewport`.

Orchestration and UI:

- `main.swift` — entry point; runs debug flags before the app loop.
- `PierApp.swift` — `AppDelegate` (App Nap assertion) and `MenuBarController`
  (status item, panel show/hide/placement, dismissal monitors, engine actions).
- `PortMonitor.swift` — the refresh cycle, grouping, kill/stop, engine commands.
- `PortListView.swift` — the panel.
- `PortPreviewView.swift` — inline web preview (non-persistent WKWebView,
  `pageZoom` desktop viewport).
- `LogPanelView.swift` — inline log tail.
- `ResizeHandle.swift` — AppKit resize handles (edges + corner).
- `ProcessRunner.swift` — subprocess with SIGKILL watchdog, stdout **and**
  stderr, optional environment for secrets.
- `DebugFlags.swift` / `FixtureRender.swift` — the probes and fixture renders.

## Build & packaging

- `scripts/build-app.sh` — SPM build → `dist/Pier.app`, copies
  `Pier_Pier.bundle` (SPM executable resources — `Bundle.module` resolves only
  if it's in `Contents/Resources/`) and `assets/Pier.icns`, ad-hoc signs.
- `scripts/render-icons.sh` — `assets/icon.svg` → PNG/icns; backend auto-detected
  (rsvg-convert → Chrome headless → Playwright → qlmanage).
- `scripts/convert-icons.sh` — brand icons → 32px PNGs. Sources are **not** in
  the repo; set `PIER_ICON_SRC`. The PNGs are checked in, so building never needs
  this.
- `Tests/PierTests` — 152 tests, all over pure functions and fixture strings. No
  UI tests; the fixture renders and probes cover that ground instead.

## The view layer is split by concern

`PortListView` was ~1,370 lines — a fifth of the app and twice the next-biggest
file. It's now five files, all extensions of the same type:

| File | Holds |
| --- | --- |
| `PortListView.swift` | state, `body`, the alert switch, `content` (section assembly), footer, resize edges |
| `+Chrome.swift` | header, search field, scope chips, sort menu, engine ⋯ menus, banners |
| `+Activity.swift` | Docker / Apple Containers / MCP sections |
| `+Rows.swift` | port rows, clusters, expansion, every row sub-piece |
| `+Events.swift` | the start/stop feed |

**Extensions, not new `View` structs.** The pieces share a lot of `@State` — the
expanded row, the hovered row, the pending confirmation, the collapsed set — and
threading all of it through as bindings would trade one kind of complexity for a
worse one. Swift only lets extensions see `private` members within the same
file, so members crossed by the split are module-internal now; they remain
invisible outside the Pier module, which is the boundary that matters.

**The split was verified by pixel-diffing the fixture renders.** All eight PNGs
(`make fixture`) came out byte-identical before and after, which is a stronger
statement about a mechanical view refactor than any test this repo could
reasonably write. Do the same for the next one.

## Deliberate constraints

- Every external tool is optional, and a failure must **say why**: a missing CLI,
  a stopped engine and a refused socket look identical in an empty list, so each
  gets its own state, stated **once** — in the section header, with the action
  beside it. Silent degradation was a bug here twice; so was saying the same
  state in three places at once.
- No network, no shell, and no disk writes beyond `UserDefaults` UI prefs and
  `~/Library/Logs/Pier/pier.log`. Secrets never enter argv, and never reach the
  log — see `PierLog`.
- Long-lived state the UI reads through `@AppStorage` must not be written during
  a drag — it rebuilds the whole list. See `ResizeHandle`.
