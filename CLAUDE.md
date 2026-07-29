# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

**Pier** — a macOS menu bar app that lists every listening port on the machine,
attributes each one to the agent harness / cmux session that spawned it, and
manages the container engines and MCP servers running alongside them.

Plain SPM executable (`swift build`), macOS 13+, no Xcode project, no third-party
dependencies. UI is SwiftUI hosted in an AppKit panel.

## Commands

```bash
make            # list every target
make build      # SPM build → assembles + ad-hoc signs dist/Pier.app
make test       # headless unit suite
make run        # rebuild, then relaunch the menu bar app
make fixture    # render the panel to PNGs with fixture data
```

Prefer `make run` over launching by hand — it kills the old instance first, and
`open` races a still-dying PID otherwise.

## The verification pattern — use it

This app's behavior lives in the menu bar, in other processes, and in CLIs that
may or may not be installed. Almost nothing can be verified by reading code, and
**fixture renders deliberately cannot verify the live paths** (they substitute
static content for the WKWebView and the log tailer). So every subsystem has a
CLI probe that runs the real code against the real machine and prints what it
found:

| Probe | Answers |
|---|---|
| `--print-groups` | the exact sections/rows the panel would show (attribution end-to-end) |
| `--print-activity` | live Docker / Apple Containers / MCP detection |
| `--print-docker` / `--print-apple` | engine state + reclaimable space (read-only, never prunes) |
| `--print-cmux` | whether workspace grouping can work, and why not |
| `--probe-anchor` | where the panel landed vs its menu bar icon |
| `--print-menubar` / `--watch-menubar` | which displays reserve bar space; observe hide/reveal signals |
| `--probe-panel-stable` | that the panel stays where it opened |
| `--probe-resize` / `--probe-resize-perf` | that the window follows a resize; per-tick cost |
| `--probe-viewport <url>` | the CSS viewport a real preview gets |
| `--tail-docker <container>` | that `docker logs --follow` really streams |
| `--render-fixture*` | layout, without touching the live menu bar |

**When you change one of these subsystems, run its probe.** When you add one, add
a probe. Several bugs this session were found only because a probe printed a
number that contradicted a confident assumption — and at least two wrong
conclusions were shipped in prose *before* a probe was written.

Two rules learned the hard way:

- **Measure distributions, not averages.** Three consecutive runs of the same
  build reported 3ms, 11ms and 12ms per resize tick on this machine. `--probe-
  resize-perf` reports min/median/p90 after warmup for that reason.
- **A green fixture render proves layout, nothing else.** If the thing you
  changed talks to a process, a socket or a webview, the fixture will happily
  render a lie.
- **Probes can have side effects on the user's app.** `--probe-resize-perf`
  persists panel sizes as part of measuring the old code path, which once left
  the live panel stuck at its minimum size. Check what a probe writes before
  running it repeatedly, and reset after: `defaults delete com.hermosalabs.pier
  panelWidth panelHeight`.

## Architecture

See `docs/architecture.md` for the pipeline and file map. The short version:

- Everything that parses is a **pure static function over strings**
  (`LsofParser`, `ProcessTable`, `CmuxSnapshot`, `ActivityParser`, `Attributor`,
  `DockerControl`, `AppleControl`, `LogText`, `PanelSize`, `PanelPlacement`).
  Tests feed them captured real output — no mocking, no fakes.
- `PortMonitor` is the only orchestration: it polls on a background queue and
  publishes to `@Published` properties.
- Views are dumb. If logic is worth a test, it does not belong in a view.

**When adding a parser, paste the real CLI output into the test.** Every parsing
bug found here came from output that differed from what the format "obviously"
was — `container system df` writes `624.3 MB` where Docker writes `3.109GB`;
`container list` has nine columns, not six.

## Traps this codebase already paid for

Do not re-learn these. Each has a test locking it in.

1. **Never trust a CLI's own status command.** `docker desktop status` printed
   `Status running` while the socket didn't exist. Engine state comes from a real
   API call — *including its text*, because `docker ps` and `container list` both
   **exit 0 while their engine is down**.
2. **`ps ucomm` is not the process's identity.** It's truncated to ~15 chars and
   is just `node` for most agent CLIs. Harness attribution also reads the full
   command line — but path matching is **opt-in per rule** (`pathTokens`),
   because generic tokens like `code` and `pi` match ordinary directories
   (`~/code/`, `~/code/pi-workflow`) and would mislabel every dev server.
3. **Word boundaries, not prefixes.** `"CodexBar".hasPrefix("codex")` reported a
   usage monitor as the Codex harness.
4. **cmux ships a commented-out example block containing real-looking settings.**
   Strip `//` comments before reading config, or you'll conclude the socket is
   already open when nothing was ever set.
5. **Secrets never go in argv.** `ps` is world-readable; the cmux password goes
   through `CMUX_SOCKET_PASSWORD` in the child environment.
6. **Stacked `.alert(item:)` modifiers silently don't present.** SwiftUI shows
   one per view — three of them meant the force-kill prompt never appeared, so a
   process that ignored SIGTERM looked like "kill did nothing". One `pending`
   enum drives one alert.
7. **Multi-display breaks the obvious panel APIs.** macOS installs a status-bar
   window *per screen*; both `MenuBarExtra` and `NSPopover(relativeTo:of:)` put
   the panel on the primary display while the icon sat on another. The frame is
   computed from the live button rect instead.
8. **Don't resize a window from a SwiftUI `DragGesture`.** Translation is
   measured in the grip's own coordinate space, and the grip moves with the
   window, so the drag stalls. Resize from absolute mouse position, in AppKit, and
   persist once on mouse-up — persisting per tick rebuilds the whole list.
9. **A GUI app has no stdin.** Any CLI that might prompt will hang until its
   timeout: `container system start` needs `--enable-kernel-install`.
10. **The menu bar can disappear from under the panel, and nothing obvious tells
    you.** `NSMenu.menuBarVisible()`, `NSStatusBar.thickness` and
    `NSScreen.visibleFrame` are all **static** across an auto-hide cycle — a
    display hosting a fullscreen space reports 0pt reserved whether the bar is up
    or not (measured: `--watch-menubar`). The signal that moves is the menu bar's
    own window (layer 24, Window Server) dropping out of `CGWindowListCopyWindowInfo`
    — see `MenuBarVisibility`. Pier uses that state only when the panel opens,
    then leaves the panel fixed. Following the bar made the panel jump whenever
    the pointer crossed the top edge.

    This one is also the cautionary tale for the probe discipline above: the
    first attempt shipped a follow loop verified only against an artificial
    nudge. The mechanism worked and the trigger never fired, so nothing changed
    on screen. Once the trigger worked, the motion was worse than the static gap,
    so `--probe-panel-stable` now verifies the opposite behavior. **Verify the
    trigger and the user-visible outcome, not just the machinery.**
11. **The status item moves after you open the panel.** Its width tracks the port
    count, and menu bar items are right-aligned, so a wider item's left edge
    shifts left. `--probe-anchor` therefore shows a systematic-looking offset
    (`left edges +8pt`) that is correct behavior — it prints `button at open:`
    alongside the current rect so you can tell that apart from a real
    misplacement. Chasing this cost a round of instrumentation; the report exists
    so it costs nobody else one.
12. **`docker ps` hides stopped containers, and an empty section reads as "the
    engine is down".** A machine whose Compose stack was stopped showed nothing
    under Docker — same visual as a dead daemon, and no way to restart anything.
    Both engines are now queried with their include-all flag (`docker ps -a`,
    `container list --all`); stopped rows sort last, dim, and carry a persistent
    Start button. Anything that lists containers must keep the `-a`/`--all`.
13. **`lsof` truncates COMMAND to 9 characters** unless you pass `+c 0` —
    "python3.11" arrives as "python3.1", and every row (and every start/stop
    event) named the wrong process. Same class as trap #2, different tool. `+c 0`
    also brings `\x20`-escaped spaces ("Cursor\x20Helper\x20(Plugin)"); decode
    them **after** tokenizing (`LsofParser.unescape`) — the escaping is exactly
    what keeps the columns splittable.
14. **Apple's own services run as you, on unprivileged ports.** ControlCenter
    serves AirPlay on :5000; the root-or-port<1024 test called it yours, and it
    outranked real dev servers. The tell is the executable path
    (`Attributor.isSystemBinary`): `/System/`, `/usr/libexec/`, `/usr/sbin/`,
    `/Library/Apple/` are SIP-protected, so nothing of yours is there. `/usr/bin`
    is **not** on that list — `python3 -m http.server` may well be yours.
15. **A missing menu bar icon has four unrelated causes**, and fixing the wrong
    one looks like the fix didn't work: App Nap dropping the item, a stale
    `NSStatusItem VisibleCC <name> = false`, a corrupt
    `NSStatusItem Preferred Position <name>`, and macOS force-hiding it. See
    `StatusItemRepair.swift` and `docs/troubleshooting.md`. Two ordering rules are
    load-bearing: the position repair must run **before** the status item is
    constructed, and the visibility sweep must run **once** or it overrides a
    user who deliberately hid the icon.
16. **`NSStatusItem.button.window.screen` is nil on a perfectly healthy item**
    whenever its menu bar isn't currently drawn — the normal state for an item
    on a display running a fullscreen Split View space. It looks like exactly
    the signal you want for "the system hid my icon" and it is not; including it
    flagged a visible icon. Only `window == nil` means hidden.
17. **The chip row is full at the 340pt minimum panel width.** Add one more
    control and the chip labels wrap mid-word ("Co/nta/ine/rs"). Every other
    fixture renders at the 440pt default and hides this, so grade new header or
    chip-row controls with `--render-fixture-narrow`.

## Sorting

`PortSort` + `ActivityRank` (pure, tested). Two rules that look wrong until you
know why:

- **Never score on instantaneous CPU.** A dev server idles at 0% between
  requests. Score on the recent *peak* of the CPU series — it also keeps the
  order stable across refreshes.
- **Every comparator must be a total order** (fall through to port, then id).
  A partial order lets rows swap on each 5s refresh, which reads as a bug and is
  miserable to reproduce. `testOrderingIsTotalForIdenticalScores` pins it.

## Start/stop events

`PierEvent` + `EventDiff` (pure, tested) diff consecutive refreshes; `PortMonitor`
applies them. Three invariants that are easy to break and expensive to notice:

- **Cold start emits nothing.** `EventDiff.between(old: nil, …)` returns `[]`.
  Break it and launching Pier announces all ~37 running things at once.
- **Containers flip `isRunning`; they don't appear and disappear.** Both engines
  are listed with `-a`/`--all`, so diffing on *presence* misses every stop.
- **Pier's own actions must be tagged.** Every action calls
  `expect(_:subject:)` before running, so the resulting event reads "you".
  Add an action without an `expect` and clicking Stop alerts you about yourself
  five seconds later. `--probe-self-event` is the only check that reaches this.

## Where the logs are

Two unrelated kinds of "logs" live in this app; don't confuse them.

1. **Pier's own log** — `~/Library/Logs/Pier/pier.log` (rotates once at 512 KB
   to `pier.log.1`). This is the first place to look when debugging the running
   app: launches, engine state transitions, and every action Pier took.
   `make applog` (last 50 lines), `make applog N=200`, `make applog-follow`, or
   `.build/debug/Pier --log-path`. Implementation: `Sources/Pier/PierLog.swift`.
2. **Other processes' logs** that Pier *shows in the panel* — live
   `docker logs --follow`, 2-second `container logs` snapshots, or 2-second cmux
   surface scrollback snapshots. Capped in memory, **never written to disk**.
   Implementation:
   `Sources/Pier/LogTail.swift`; probe with `make logs C=<container>`.

## Conventions

- Swift, 2-space indent, enforced by Xcode's bundled `swift-format` (no install
  needed — `xcrun swift-format`). `make fmt` formats, `make lint` fails on
  violations, **`make check` is the gate**: lint + the full suite. Config lives
  in `.swift-format`. Comments explain
  **why**, especially where the code looks odd because reality is odd — those
  comments are load-bearing and shouldn't be "cleaned up".
- Every external tool is optional. A missing CLI, a stopped daemon, or a refused
  socket must degrade to an empty section **and say why** — silence that looks
  identical to "nothing is running" is a bug, not graceful degradation. Say it
  **once**, in the section header: three simultaneous "Docker isn't running"
  notices is the opposite failure. Never show a count for a state you haven't
  counted (an unreachable engine gets no `0` pill).
- Destructive actions confirm first and name exactly what they remove. Only
  volume prunes destroy data; their wording says so explicitly.
- No telemetry, update checks, or background service API calls. Preview
  navigation stays on the selected host, but WebKit may still load remote
  subresources referenced by that page. No shell (`ProcessRunner` takes argv
  arrays). On disk: only `UserDefaults` UI prefs and
  `~/Library/Logs/Pier/pier.log`. Treat `docs/privacy-and-security.md` as a
  contract to keep, not a description to update casually.
- **Log verbs and names, never argv.** `PierLog.shared.log(…)` takes things like
  `"stop docker container data_redis"`. Never pass a command line, environment,
  or captured tool output — `ps` command lines routinely contain `--api-key=…`.
  `PierLog.redact` masks credential-shaped `key=value` pairs, but it's a
  backstop, not permission to log argv. The single exception is a failed tool's
  error text, and it goes through `PierLog.summarize` (first line, 200 chars).

## Refactoring the view layer

`PortListView` is split across `PortListView+{Chrome,Activity,Rows,Events}.swift`
as extensions of one type — see `docs/architecture.md`. Two rules:

- **Verify a view refactor by pixel-diffing the fixtures**, not by eye. Render
  all eight before, refactor, render after, `cmp` them. Byte-identical is the
  bar; anything else needs an explanation.
- **Extensions can't see `private` across files.** Moving a member into one of
  these files means dropping `private`. That is the accepted cost of the split;
  don't "fix" it by re-adding `private` and moving the member back.

## CI

`.github/workflows/ci.yml` — lint → build → test on macOS, ~50s. It invokes the
same `make` targets you run locally; **change the Makefile, not the workflow**,
so the two can't drift.

- Run `make check` before pushing. It's lint + tests, which is what CI gates on
  minus the bundle assembly.
- macOS minutes bill at 10×. Don't add a matrix, a scheduled run, or a second
  macOS job without a reason worth the spend.
- **Don't add a CodeQL workflow** — scanning is already configured as GitHub
  Apps at the account level, and it's invisible from `.github/`.
- **A docs-only PR gets *no* checks, not a passing one.** `paths-ignore` skips
  the workflow entirely, so `gh pr checks` reports "no checks reported"
  (observed on #1). Harmless today. The day a ruleset *requires* the
  `lint · build · test` check, those PRs become unmergeable — the standard fix
  is a second always-runs job with the required name that no-ops on skipped
  paths. Remember this before turning on required checks.

## "Unreachable" is two different faults

`docker ps` failing does not tell you *why*, and the two whys need opposite
responses:

- **`.notRunning`** — nothing is listening. Start is the right offer.
- **`.failing(reason)`** — something answered and refused. Start does nothing;
  the message is the whole value.

Collapsing both into "not running" once cost a live debugging session: Docker
Desktop's proxy was answering the socket while unable to reach dockerd in its
VM (`no route to host`), so every call 500'd. Pier said "not running" under a
Start button, `docker desktop status` said "running" (trap #1), and the actual
error was visible nowhere. `DockerControl.fault(from:)` classifies it now and
the section header shows the engine's own words in its tooltip.

## Security invariants

Three properties the README states as fact. Breaking one is a bug, not a
regression in polish:

- **No top-level navigation beyond the previewed host.** The preview's
  `WKNavigationDelegate` must keep a `decidePolicyFor` handler backed by
  `PreviewNavigationPolicy`. Removing it re-opens the hole where any previewed
  page can redirect Pier to an arbitrary external host. This does not block
  external subresources referenced by the page; documentation must not claim it
  does.
- **Secrets never enter argv.** `ps` is world-readable; the cmux password goes
  through the child's environment. `PierLog` logs verbs and names, never argv.
- **The log is 0600 in a 0700 directory.** It lists every service, container and
  agent process on the machine.

## Branching: work goes through PRs

`main` is the deploy-ish branch and everything lands via pull request, even
solo work. Two reasons, both concrete:

- **CI gates the change before it lands**, instead of telling you afterwards
  that `main` is red.
- **Greptile only reviews pull requests.** Pushing straight to `main` means the
  review integration never sees the code at all.

```bash
git checkout -b <topic> && git push -u origin <topic> && gh pr create
```

Branch protection can't enforce this — it needs GitHub Pro on a private repo
(the API returns 403 today) — so it's a convention. If the repo ever goes
public, or the account upgrades, enable a ruleset requiring the `lint · build ·
test` check.

## Working rules

- **Never validate against a stale binary.** UI and runtime claims must be
  checked against a freshly built bundle:
  `make build && pkill -f "Pier.app/Contents/MacOS/Pier"; open dist/Pier.app`.
  A `swift build` alone does not update `dist/Pier.app`.
- **Probes must never trigger auth or permission UI.** Anything that could raise
  a Keychain prompt, a TCC dialog, or a notification-authorization prompt is a
  live action, not a probe. Read the cmux password from its config, use captured
  fixtures, and keep permission-requesting code behind an explicit
  `--probe-*` flag the user runs deliberately.
- **A probe that doesn't recognize its own flag falls through into the app loop
  and hangs.** When adding one, rebuild before running it.

## Before publishing / releasing

- `Sources/Pier/Resources/icons/` holds ~39 third-party **trademarks**.
  Redistribution is an unresolved licensing decision (README flags it).
- There is **no LICENSE file** — without one, published code is all-rights-reserved.
- `dist/` and `.build/` are gitignored; the ad-hoc signed app is not for
  distribution (that needs Developer ID + notarization).
