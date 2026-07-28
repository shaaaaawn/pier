# Pier

A macOS menu bar utility for a dev machine running too many things at once.

It lists every listening port, **attributes each one** to the AI agent harness or
cmux (terminal multiplexer) session that spawned it, and lets you preview, tail,
or kill it. Alongside the ports it surfaces the rest of the background work —
**Docker** and **Apple `container`** containers and the **MCP servers** your
agents spawned — with per-row CPU, inline log tailing, and engine lifecycle and
prune controls.

Everything is derived from bounded CLI probes (`lsof`, `ps`, and optionally
`cmux`, `docker`, `container`). No network, no shell, and the only things it
writes are UI preferences and its own local log at
`~/Library/Logs/Pier/pier.log` — see
[Privacy & security posture](#privacy--security-posture).

## Build & run

```sh
make build   # SPM build, assembles + ad-hoc signs dist/Pier.app
make test    # unit suite
make run     # rebuild, then (re)launch the menu bar app
```

(`make` alone lists targets; the scripts behind them — `./scripts/build-app.sh`,
`swift test` — work directly too, as do `swift build` / `swift run Pier`.)

### Fixture renders — layout, without the live menu bar

`make fixture` writes PNGs of the panel with fixture data (no app loop):

| Flag | What it renders |
|------|-----------------|
| `--render-fixture <png> [scope]` | the list; `scope` preselects a chip (`web`, `mcp`, …) |
| `--render-fixture-expanded <png>` | a row with its web preview already open |
| `--render-fixture-logs <png>` | a Docker row with its log tail open |
| `--render-fixture-activity <png>` | short port list, so Docker/MCP sections sit above the fold |
| `--render-fixture-preview <png>` | the preview card in loaded / loading / error states |
| `--render-fixture-idle <png>` | engines running with **no containers** — sections must not vanish |
| `--render-fixture-down <png>` | engines installed but **not running** — one statement each, inline Start |
| `--render-fixture-events <png>` | the start/stop feed, with its actor column |
| `--render-fixture-narrow <png>` | the list at the **340pt minimum** width — where the chip row overflows |

### Probes — the live paths fixtures can't reach

Fixture renders deliberately substitute static content for the `WKWebView` and
the log tailer, so a green render proves **layout only**. Anything that talks to
a process, a socket or a webview has a probe that runs the real code against this
machine and prints what it found:

| Probe | Answers | Make target |
|---|---|---|
| `--print-groups` | the exact sections/rows the panel would show | |
| `--print-activity` | live Docker / Apple Containers / MCP detection | `make activity` |
| `--print-docker` | Docker engine state + reclaimable space (never prunes) | `make docker` |
| `--print-apple` | the same for Apple's `container` | `make apple` |
| `--print-cmux` | whether workspace grouping can work, and why not | `make cmux` |
| `--probe-anchor` | where the panel landed vs its menu bar icon | `make anchor` |
| `--probe-resize` | that the window follows a resize, top edge planted | |
| `--probe-resize-perf` | per-drag-tick cost as min/median/p90 | |
| `--probe-viewport <url> [png]` | the CSS viewport a real preview gets | `make viewport URL=…` |
| `--tail-docker <container>` | that `docker logs --follow` really streams | `make logs C=…` |
| `--tail-log [n]` | Pier's own recent log lines | `make applog [N=…]` |
| `--log-path` | where Pier writes its log | |
| `--probe-self-event` | that Pier's own kills read as "you", not as an unattributed stop | `make selfevent` |
| `--probe-statusitem` | persisted defaults that can hide or misplace the menu bar icon | `make statusitem` |
| `--probe-notify` | whether this bundle may post a system notification (it may not — see below) | |

All the `--print-*` probes are read-only: none of them prune, start or stop
anything.

## When the menu bar icon goes missing

Four unrelated faults produce the identical symptom — Pier is running, no icon —
and each needs a different fix. Three are handled in
[`StatusItemRepair.swift`](Sources/Pier/StatusItemRepair.swift) (ported from
CodexBar, which hit all of them in the field); the fourth is the App Nap
assertion in `AppDelegate`.

| Fault | What it looks like | What Pier does |
| --- | --- | --- |
| App Nap drops the item | icon vanishes while the process keeps running | `beginActivity` held for the app's lifetime |
| `NSStatusItem VisibleCC <name> = false` | never appears again, across relaunches and rebuilds | cleared **once** at launch |
| `NSStatusItem Preferred Position <name>` corrupt | placed off-screen (`<= 0`, or past every display) | cleared **before** the item is created |
| macOS force-hides it | nothing to repair | detected and logged |

Two details that matter:

- **The position repair must run before the status item exists.** Clearing a bad
  coordinate afterwards doesn't move an item that's already placed.
- **The visibility sweep runs once**, guarded by `hasRepairedStatusItemDefaults`.
  Repeating it every launch would override a user who later hides the icon on
  purpose.

Pier also now sets a stable `autosaveName` (`pier-status-item`). Without one
macOS keys this state by launch-order index (`Item-0`, `Item-1`, …), which moves
between runs — so there is no stable key to repair, and the icon's position
isn't reliably restored. Adopting the name repositions the icon once; the
repairs still clean up the old `Item-N` keys.

`make statusitem` prints the persisted keys and flags any the repair would
clear, without writing anything.

## Menu bar panel placement

The panel is an `NSStatusItem` plus a borderless `NSPanel` whose frame is
computed from the live status-button rect (`PanelPlacement.frame`) —
**left-aligned** to the item (the panel's left edge under the item's left edge,
as a menu bar menu opens), 6pt below the menu bar, clamped into the item's own
display. An item near the right edge slides inward instead of hanging off, which
is what makes a right-hand item's panel look right-aligned.

Both obvious alternatives place it wrong once you have **more than one
display**: macOS installs a status-bar window *per screen*, and SwiftUI's
`MenuBarExtra` and `NSPopover(relativeTo:of:)` both end up putting the window
on the primary screen. Measured with `--probe-anchor` on a three-display setup:

```
button:  x4766 y1294        ← icon, on the right-hand display
panel:   x0    y708         ← NSPopover, primary screen's left edge (wrong)
panel:   x4502 y662         ← computed placement (icon's own display, correct)
```

Two further wrinkles the placement math handles, both covered by
`PanelPlacementTests`: a status-bar window can report a Y *above* its own
screen's frame (anchor to the menu bar's lower edge or the panel's top hides
behind it), and an item near a screen edge needs the panel to slide inward.

Check it yourself — no clicking required:

```sh
make anchor
```

`make anchor` reports a **left edges +8pt** style offset that is *not* a bug, and
the report says so explicitly. The status item's width changes with the port
count (` 9` → ` 41` is 8pt wider), and menu bar items are right-aligned, so a
wider item's **left edge moves left**. The panel is aligned to where the item was
when it opened; like a real menu, it doesn't chase the item afterward. The report
prints `button at open:` next to the current rect so the two can be compared
before anyone goes looking for a placement bug.

Dismissal matches a menu: click anywhere outside, press Escape, or click the
item again.

### The menu bar can vanish while the panel is open

In a fullscreen space — or with **System Settings → Desktop & Dock →
Automatically hide and show the menu bar** on — the bar reveals on hover and
hides again once the pointer moves away, *including while this panel is open*.

macOS offers no way for a custom panel to pin the bar down: it only holds the bar
for a real `NSMenu` that's tracking. So instead of pretending otherwise, the panel
**follows** the bar — it re-anchors to the screen's top edge when the bar isn't
drawn, rather than hanging a bar's height below where the bar used to be.

Detecting that turned out to be the hard part, because **none of the obvious
signals move.** Sampled over 12s while the bar auto-hid and revealed
(`--watch-menubar`):

| Signal | While the bar hides |
|---|---|
| `NSMenu.menuBarVisible()` | stays `true` |
| `NSStatusBar.system.thickness` | stays `22` |
| `NSScreen.visibleFrame` | never changes — a display hosting a fullscreen space reports **0pt reserved** whether the bar is up or not |
| the status item's own Y | stale: reports where the bar *was* |

What does move is the **menu bar's own window**. The window server keeps one
thin, full-width window at layer 24 per drawn bar, and it leaves the on-screen
list when the bar retracts (`MenuBarVisibility`). Bounds and owner are readable
without Screen Recording permission — only window contents and names need it.
A display that permanently reserves bar space short-circuits to "visible", so
ordinary displays never depend on the window lookup.

Only the **vertical** anchor is followed. The item's horizontal position jitters
as its own title width changes (the port count gaining a digit is worth 8pt), and
chasing that would slide the panel sideways while you're using it.

```sh
Pier --print-menubar            # which displays reserve bar space right now
Pier --probe-menubar-follow     # nudge the panel stale, verify it's corrected
```

`--print-menubar` is the quick way to see the state — on a three-display setup
with one fullscreen app it prints `30pt reserved`, `32pt reserved`, and
`NOT reserved (hidden / fullscreen space)`.

## Docker controls

The Docker section header carries an **⋯ menu**:

- **Engine** — Start / Stop / Restart, via `docker desktop start|stop|restart`
- **Clean up** — Prune Unused, Prune Images, Prune Build Cache, and Prune
  Everything Including Volumes

The menu's section title shows what `docker system df` says is reclaimable
(e.g. "Reclaimable: Images 3.1GB · Local Volumes 397.1MB"), refreshed whenever
the panel opens, so a prune is an informed click. Every removing action
confirms first and says exactly what goes: the safe prune promises named volumes
are kept; only **Prune Everything** deletes volume data, and its confirmation
says so in as many words with a "Delete Anyway" button.

When the daemon isn't answering, the section header says so and offers **Start**
inline: `Docker · not running · [Start] · ⋯`.

### One statement per state

An engine that's down used to be announced three times at once — a pinned banner
above the list, a row inside the section, and a `0` count pill. The pill was
worse than redundant: with the engine down nobody has counted the containers, so
`0` asserted something unknown. Each state is now said exactly once:

| Engine state | What the panel shows |
|---|---|
| Running, containers present | `Docker 4 · 1 stopped` + the rows |
| Running, none at all | `Docker 0` + a single "No containers" line |
| Installed, not running | `Docker · not running` + an inline **Start** — no count, no body row |
| CLI not installed | no section (there is nothing to act on) |

The pinned banners existed only because an empty section used to *vanish*,
taking its ⋯ menu with it. Sections now persist for any installed engine, so the
banners had nothing left to do. `--render-fixture-down` renders this state.

## Apple Containers controls

The Apple Containers section header has its own **⋯ menu**, mapped to
`apple/container` 1.1.0's real surface:

- **Services** — Start / Stop (`container system start|stop`)
- **Clean up** — Prune Stopped Containers (`container prune`), Prune Dangling
  Images (`image prune`), Prune All Unused Images (`image prune --all`), Prune
  Unused Volumes (`volume prune`), Delete Builder Container (`builder delete`)

Reclaimable space comes from `container system df`, same as Docker's.

Three deliberate differences from the Docker menu, because the CLI differs:

| | Docker | Apple `container` |
|---|---|---|
| Aggregate prune | `system prune` does everything | **none** — prune each resource type separately |
| Restart | `docker desktop restart` | **no such command**, so none is offered |
| Prune prompts | needs `-f` | doesn't prompt; no force flag exists |

Two traps, both found by running it rather than reading about it:

1. **`container list` exits 0 while the engine is down**, printing
   `XPC connection error: Connection invalid`. Exit code alone reports a healthy
   engine — the same shape as Docker's, so `AppleControl.state` inspects the text.
2. **`container system start` prompts to install the kernel** on a first run. A
   prompt inside a GUI app with no stdin hangs until the timeout, so the action
   always passes `--enable-kernel-install`.

And one formatting difference that produced a wrong number until it was run
live: Apple writes sizes as `624.3 MB` (space before the unit) where Docker
writes `3.109GB`. Splitting the reclaimable value on whitespace reported
"Images 624.3" — a figure with no unit. `DockerControl.sizeOnly` strips the
percentage instead.

`Pier --print-apple` reports engine state (including the exit-code discrepancy)
and reclaimable space. Read-only: it never prunes and never starts the service.

### Engine state comes from the API, not from `docker desktop status`

Verified on this machine: `docker desktop status` printed `Status running` while
the socket didn't exist and every command failed with "failed to connect to the
docker API". State is therefore derived from a real `docker ps` — including its
*text*, since some versions exit 0 while printing the connection failure.
`Pier --print-docker` reports engine state, the status-command discrepancy, and
reclaimable space (read-only; it never prunes).

## Log tailing

Rows expand into one of two drawers — the web preview (eye) or a **log tail**
(`text.alignleft`). Docker rows also expand on a plain row click. The panel is
monospaced, pinned to the newest line (pausable), copy-all in the header, and
tints `error`/`fatal`/`panic`/`traceback` red and `warn` orange so the problem
line finds you.

Sources, and honestly what each one can do:

| Row | Source | Mode |
|---|---|---|
| Docker container | `docker logs --tail 300 --follow` | live stream |
| Apple container | `container logs` | 2s snapshot poll (no `--follow` upstream) |
| cmux-attributed port | `cmux read-screen --surface <ref> --scrollback` | 2s snapshot poll |
| MCP server | — | stdio belongs to its harness; nothing to read |
| Plain dev server | — | output went to the terminal that started it |
| System process | — | Console.app |

The cmux route is what makes a **dev server's own output** reachable: Pier keeps
each row's surface ref, so it can read that surface's scrollback (ANSI stripped).
It needs cmux socket access — see the cmux section above.

Two implementation notes worth keeping: a pipe chunk can end mid-line, so the
tailer carries the partial line to the next read (`LogText.split`); and lines are
capped at 800, oldest dropped, so a chatty container can't grow without bound.

Fixture renders substitute static lines and therefore **cannot** verify
streaming — use the live probe:

```bash
.build/debug/Pier --tail-docker data_postgres
```

## Preview viewport

A 456pt-wide card would make responsive sites render their phone layout. The
preview instead sets `WKWebView.pageZoom = cardWidth / target`, which *reflows*
the page (Safari's Cmd+− behavior), so a 1280px target gives the page a genuine
1280×800 CSS viewport scaled down to fit — and the card is sized 16:10 to match.
`magnification` would only scale visually and clip; a layer transform would
break click coordinates.

Pick the width from the address bar (1280 / 1440 / 1024 / Fit); the choice
persists. Verify against a live server with:

```sh
make viewport URL=http://127.0.0.1:3000
```

## Features

- Menu bar extra (no Dock icon) with a live count of listening TCP ports. The
  glyph is a **template image**, so macOS inverts it automatically — dark on a
  light menu bar, light on a dark one — and tints it while the panel is open.
  The count uses monospaced digits so the item doesn't jitter as it changes.
- Enumerates listeners via `lsof -nP -iTCP -sTCP:LISTEN` and `lsof -nP -iUDP`,
  deduped by pid+port+protocol (multiple bind addresses merged).
- Per-row actions: Kill (SIGTERM, with an offered SIGKILL force-kill if the
  process survives ~2s), Open in Browser, Copy `localhost:<port>`.
- **Click anywhere on a row** to open/close its inline web preview (rows with
  no browsable URL — UDP — stay inert). The eye button still works too.
- **Per-row usage**: CPU sparkline + percentage in the trailing slot, swapped
  for the action buttons on hover so rows never reflow. Tinted gray when idle,
  accent when busy, orange above 80%. Memory is in the tooltip. The bars are
  scaled to *that process's* own peak (5% floor) so an idle server reads as a
  baseline instead of a full bar — the number carries the absolute value.
  Sourced from the existing `ps` probe (`%cpu`, `rss` ride along on the
  ancestor-chain call), with ~2 min of history per pid, pruned as pids exit.
  Containers show no sparkline: they have no host pid (that needs `docker stats`).
- Hover a row to see the full command line.
- Search/filter by port, process name, harness, or workspace, plus **scope
  chips** (All · Web · Ports · Docker · MCP), a **hide-system** toggle, and
  **click-to-collapse** section headers. Scope and system visibility persist
  across launches.
- Auto-refresh every 5s while the window is open, every 30s in the background,
  plus refresh-on-appear and a manual refresh button.
- Rows are grouped by harness attribution (unattributed and system last) and
  sorted by port within each group.
- Known harnesses show their brand icon in the badge and group header
  (32px PNGs in `Sources/Pier/Resources/icons/`, text fallback if missing).

## Attribution

For each listening PID, Pier walks the ancestor chain (`ps -axo pid,ppid,ucomm`
snapshot) and combines two signals:

- **cmux** — if `cmux` is available (`/Applications/cmux.app/.../bin/cmux`,
  Homebrew, or on PATH), `cmux top --all --processes --flat --format tsv` is
  parsed to map processes to surfaces and workspaces. A listener whose pid or
  any ancestor belongs to a cmux surface is labeled
  `cmux · <workspace> · <surface>`.
- **Known harnesses** — `claude`, `codex`, `kimi`, `opencode`, `gemini`,
  `aider`, `cursor`, VS Code, `Windsurf`, `ghostty`, `Terminal`, `iTerm2`,
  `tmux`, `zellij` (see `harnessTable` in `Sources/Pier/Attributor.swift`).
  Tokens match on a **word boundary**, not a bare prefix: `CodexBar` (a usage
  monitor, listed under its own name) is not the Codex harness, and `warpd` is
  not Warp. A trailing letter or digit means it's a different word; `-`, `_`,
  `.`, and space still match (`claude-code`, `Cursor Helper`).

  The chain is searched **self-first**, so a process is named by what it *is*
  before what launched it. Worth knowing when adding rules: Antigravity's CLI
  installs as `agy`, and CodexBar shells out to it — without an `agy` rule those
  ports get credited to CodexBar, which is true but much less useful. Unnamed
  children still fall back to their launcher rather than "Other".

Badges: purple for cmux-attributed, teal for harness-attributed, neutral for
unattributed dev servers, dim "system" for root-owned or privileged (< 1024)
ports.

cmux integration is optional — if the CLI is missing or errors, Pier works
normally and simply skips the cmux signal.

### Enabling cmux socket access (and a trap that cost real time)

cmux's socket defaults to `socketControlMode: "cmuxOnly"` — only processes
started inside cmux may connect — so Pier is refused and ports can't group by
workspace. To enable it, add a **real** `automation` block to
`~/.config/cmux/cmux.json`:

```jsonc
{
  "automation": {
    "socketControlMode": "allowAll",
    "socketPassword": "<a long random string>"   // optional; Pier reads it
  },
  …
}
```

**The trap:** cmux ships that file with a large commented-out example block
which already contains `"socketControlMode" : "allowAll"`. Editing *that* line
changes nothing — and a regex over the raw file happily matches it, so Pier
reported "already configured, restart cmux" while the setting had never been
set. `CmuxAccess.stripComments` now removes `//` comments (respecting string
literals) before reading the two keys, which is what
`CmuxConfigCommentTests` locks in.

Also learned: no restart is needed. cmux picks the setting up on the next
connection, so `make cmux` flips from `accessDenied` to `connected` immediately.


## Background activity (Docker · Containers · MCP)

Below the port groups, Pier shows background work that doesn't necessarily
hold a host port:

- **Docker** — containers from `docker ps -a` with image · status, plus
  published host ports (`→ 8080`) with an open-in-browser action.
- **Apple Containers** — Apple's `container` engine (`brew install container`),
  marked with the Apple logo. The two engines are *sibling* sections under one
  **Containers** filter chip, deliberately: Apple's CLI is just `container`, so
  a bare "Containers" heading beside "Docker" reads as if Docker's containers
  were something else. Verified live against apple/container 1.1.0 — its `list`
  output has nine columns (IP/CPUS/MEMORY/STARTED trail STATE), which
  `ActivityTests.testParseContainerListRealOutput` pins.
- **MCP Servers** — processes whose command head names an MCP server
  (`mcp` / `@modelcontextprotocol`), labeled `binary · package`
  ("node · chrome-devtools-mcp"), deduped into one row per label with a ×N
  count, and attributed to the harness/cmux surface that spawned them like any
  port. Chrome instances *launched by* an MCP server (mcp only in flag values)
  are deliberately excluded.

### Stopped containers are listed too

Both engines are queried with their include-everything flag — `docker ps -a`,
`container list --all` — not just the running set. This was a real gap: a machine
whose Compose stack was down showed an **empty Docker section**, which is
indistinguishable from "Docker isn't running", and there was no way to bring a
container back from the panel.

Stopped containers sort **after** the running ones, render dimmed, and swap the
hover-only Stop button for a persistent blue **Start** (`docker start <name>` /
`container start <name>`) — a stopped row's whole purpose is to be started, so
that one action isn't hidden behind hover. The section header qualifies its
count: `Docker 4 · 1 stopped`. A start that fails (a port already bound, a
removed volume — routine for a stale Compose stack) leaves the row where it was;
the reason is in `make applog`. "Running" is read off Docker's Status column
(`Up …` yes; `Exited …`, `Created`, `Paused`, `Restarting` no —
`ActivityParser.dockerStatusIsRunning`) and off Apple's STATE column.

Row actions: MCP rows kill their pids (SIGTERM, confirm first); container rows
run `docker stop` / `container stop`. Search filters these sections too. Each
detector degrades to empty when its CLI is missing or its daemon is down.

Rows don't repeat what their group header already says: under a "Cursor"
header the per-row badge is dropped and the process name is promoted, so the
row is one line instead of two. cmux is the exception — the header carries the
workspace, so the row keeps the surface (`make dev screens`).

## Panel size

The panel defaults to **440×560** and is resizable like a window: drag the
**right edge**, the **bottom edge**, or the corner grip (double-click the grip
to reset). The size persists (`PanelSize`, clamped to 340–760 × 300–1000).

Two things were needed to make it work *and* feel right:

**Absolute mouse position, not SwiftUI's drag translation.** The grip sits at
the panel's bottom-right, so growing the window moves the grip along with the
pointer — translation measured in the grip's own coordinate space stops
accumulating and the drag stalls after a few points. Screen coordinates don't
move when the window does (`PanelSize.dragged`; AppKit screen y increases
*upward*, so dragging down must add height).

**The drag is AppKit, not a SwiftUI gesture** (`ResizeHandleView`). The panel
size lives in `UserDefaults` and the view reads it via `@AppStorage`, so
persisting on every tick rebuilt the whole list — and the change reached the
window through a `receive(on: RunLoop.main)` hop, adding a frame of latency. The
handle now resizes the window directly in `mouseDragged` (with `display: false`
so AppKit coalesces the redraw) and persists **once** on mouse-up.

Measured per drag tick, 60 samples after warmup (`Pier --probe-resize-perf`):

```
drag tick (window resize, SwiftUI relayout): min 1.88 · median 2.79 · p90 4.03 ms
old path (persist every tick):               min 3.29 · median 4.91 · p90 8.43 ms
bare window, no SwiftUI content:             min 0.04 · median 0.04 · p90 0.06 ms
```

Report the **distribution, not an average**: three consecutive runs of the same
build averaged 3ms, 11ms and 12ms because this machine is busy, which is enough
noise to "prove" whatever you hoped. The bare-window line shows window geometry
is free — the cost is SwiftUI relayout, which is why the row sparkline is a
single `Canvas` instead of ~28 subviews per row.

`Pier --probe-resize` separately confirms the window follows a resize and keeps
its top edge planted.

Because the panel is borderless — it hangs off the menu bar and gets no system
resize handles — the grabber writes the size to defaults and the controller
resizes the window, keeping the top-left corner planted so it grows right/down
under the pointer rather than jumping mid-drag. It re-anchors to the icon on the
next open. Resizing also recomputes the preview's `pageZoom`, so
the requested CSS viewport (1280 by default) stays exact at any panel width.

## Sorting

The header's **↑↓** menu offers three orders, remembered across launches. The
glyph turns accent-colored when you're on anything other than the default.

| Mode | Order |
|---|---|
| **Activity** (default) | most interesting first — see below |
| Port | ascending port number |
| Name | process name, A→Z |

### What "activity" means

The naive version doesn't work: **a dev server idles at 0% CPU between
requests**, so ranking by the current sample puts a busy Vite server below a
polling menu bar daemon. `ActivityRank.score` uses two corrections.

- **Recent peak, not the current sample.** The score reads the maximum of the
  pid's ~2-minute CPU series. A compile spike 30s ago is better evidence that
  something is in use than this instant's idle reading — and it makes the order
  *stable*, instead of reshuffling on every 5s refresh.
- **Looking like a web server is worth more than being busy**, because that's
  what you opened Pier to find. Two tiers: a server runtime (`node`, `workerd`,
  `uvicorn`, …) scores 1000; merely sitting on a conventional port (3000, 5173,
  8787, …) scores 500. Flat scoring let anything squatting `:5000` outrank a real
  dev server.
- **Agent- and cmux-attributed listeners get a bump**; System sinks below
  everything and stays pinned last, however busy it gets.

In Activity mode the *sections* reorder too, so the group holding the liveliest
listener floats to the top — except System, which is always last. Port and Name
modes keep the semantic group order.

Every mode falls back to port, then id, so ordering is **total**. A comparator
that can return false both ways lets rows swap places on each refresh, which
reads as a bug.

Pier will not port-scan to find out what's really an HTTP server: that would
mean connecting to every listener, which breaks the no-outbound-requests posture
and can trigger side effects on someone's endpoint. The heuristics are honest
about being guesses.

### A related fix: Apple's services are now attributed to System

`ControlCenter` runs the AirPlay Receiver on **:5000** — as your user, on an
unprivileged port, indistinguishable from a Flask app by the old rules
(root-or-port-under-1024). It outranked real dev servers the moment activity
sorting landed. `Attributor.isSystemBinary` now also treats `/System/`,
`/usr/libexec/`, `/usr/sbin/` and `/Library/Apple/` executables as System. Those
prefixes are SIP-protected, so nothing of yours ever lives there — no vendor list
required. On this machine it moved 8 ports out of "Other". Note `/usr/bin` is
deliberately excluded: `python3 -m http.server` may well be yours.

## Start/stop alerts

Pier diffs consecutive refreshes and records what appeared and vanished, so
"what just killed my dev server?" has an answer. The **actor** column is the
point:

```
node · chrome-devtools-mcp    Claude Code  stopped ×3   MCP server   12 sec
node on :5173                 cmux · Idle Screens · dev  started  port   48 sec
data_redis                    you  stopped  Docker                    2 min
```

- **Where they show.** A bell button in the panel header opens the feed (newest
  first, last 200). Unseen events put a `•` after the menu bar count —
  `⚓ 19 •` — which clears when you open the panel.
- **What counts as an event.** A listening port appearing or vanishing; a
  container flipping between running and stopped; an MCP row appearing,
  vanishing, or **changing count** — a harness killing 3 of its 5 servers is one
  `stopped ×3`, which is the case worth seeing.
- **Your own clicks read as "you".** Stopping a container from Pier would
  otherwise reappear ~5s later as an unattributed kill. Each action registers a
  short-lived expectation that the differ matches and labels. Verified live by
  `--probe-self-event`, which spawns a throwaway listener, kills it through the
  same call the Kill button makes, and asserts the label.
- **Launch is silent.** A cold start seeds the baseline and emits nothing —
  otherwise opening Pier would announce all ~37 things already running.
  `EventDiff.between(old: nil, …) == []` is pinned by a test.

### The limit: it's a poller

Refreshes are every **5s with the panel open, 30s when closed**, so anything
that starts *and* exits inside one interval is never seen — a short-lived `npx`
spawn can slip through entirely. Live process events would need an
`EndpointSecurity` client, which requires an entitlement Apple grants case by
case. The empty feed says this out loud rather than letting a missed process
look like a bug.

### No system notifications (yet)

Banner notifications don't work from this build and the reason isn't fixable in
code. `--probe-notify` from the signed bundle reports:

```
bundle id:  com.hermosalabs.pier
authorized: 1 (0=notDetermined 1=denied 2=authorized)
request:    granted=false error=Notifications are not allowed for this application
```

macOS refused to register the app at all — it never appears in
`~/Library/Preferences/com.apple.ncprefs.plist`, so there's nothing to switch on
in System Settings. Ad-hoc signing with no Team ID is the likely cause; the same
thing that blocks distribution (see [Privacy & security posture]
(#privacy--security-posture)) blocks the notification center. The menu bar badge
and the feed need no permission and always work. Keep `--probe-notify` — it's
how you re-check after a Developer ID signature.

## Local logs

Pier writes its own activity log to the standard macOS location:

```
~/Library/Logs/Pier/pier.log     # current
~/Library/Logs/Pier/pier.log.1   # previous, after a 512 KB rotation
```

It's a plain text file — one ISO-8601 timestamped line per event — so `tail -f`
works and Console.app picks it up. `os_log` was the alternative and lost: Pier is
an LSUIElement app with no terminal attached, and `log show --predicate` is a bad
way to answer "what did the app just do".

```bash
make applog
```

| Command | What you get |
| --- | --- |
| `make applog` | Last 50 lines (`make applog N=200` for more). |
| `make applog-follow` | `tail -f` on the live file. |
| `.build/debug/Pier --log-path` | Print the path and exit. |
| `.build/debug/Pier --tail-log 20` | Same as `make applog`, no build step. |

What lands in it:

```
2026-07-27T18:22:14-07:00  launch — Pier 0.1.0 (74271)
2026-07-27T18:22:15-07:00  docker engine: cliMissing → ready
2026-07-27T18:22:15-07:00  apple engine: cliMissing → unreachable
2026-07-27T18:31:02-07:00  start docker container data_redis
2026-07-27T18:31:04-07:00  start data_redis: ok
2026-07-27T19:53:09-07:00  event: local started python3.11 on :8899
2026-07-27T19:55:22-07:00  event: local stopped python3.11 on :8899
```

Every start/stop event is logged too, so the feed's 200-entry window isn't the
only record — `make applog | grep event:` is the full history.

Engine **state transitions** only, not every 5-second refresh — otherwise the
interesting events drown. Container logs are a different thing: those stream
live into the panel and are not persisted (see [Log tailing](#log-tailing)).

## Privacy & security posture

What Pier does and doesn't do, since it inspects your machine:

- **No network.** The app makes no outbound requests. The only network activity
  is the inline preview's `WKWebView` loading the localhost URL you clicked, in a
  **non-persistent** data store — a previewed dev server leaves no cookies,
  localStorage or caches behind.
- **No shell.** Every subprocess is launched with an argv array (`ProcessRunner`),
  never through `sh -c`, so container and process names taken from command output
  can't be interpreted as shell.
- **Secrets never go in argv.** `ps` output is world-readable on macOS, so the
  cmux socket password is passed via `CMUX_SOCKET_PASSWORD` in the child's
  environment rather than `--password <secret>`.
- **Two things are written to disk, both local:** UI preferences in
  `UserDefaults` (panel size, filter chip, preview width), and Pier's own log at
  `~/Library/Logs/Pier/pier.log` (see [Local logs](#local-logs)). The log records
  *what Pier did* — launches, engine actions, container start/stop, kills, engine
  state changes. It deliberately **never records command lines, environment
  variables, or scan output**, because those routinely carry secrets. The one
  exception is a failed tool's error text, which is bounded to its **first line,
  capped at 200 characters** (`PierLog.summarize`) and run through
  `PierLog.redact`, which masks credential-shaped `key=value` pairs. No caches,
  no config, nothing leaves the machine.
- **Reads, in memory only:** `lsof` listeners, the `ps` process table including
  **full command lines**, and optionally `docker ps`, `container list` and
  `cmux top`. Command lines are used for harness attribution and hover tooltips
  and are never persisted — but be aware that a command line can itself contain
  a secret (`--api-key=…`), so the tooltip and the `--print-*` debug flags can
  display one.
- **Destructive actions are explicit:** kill (SIGTERM, then an offered SIGKILL),
  `docker stop` / `container stop`, and the prunes. Each is confirmed and names
  what it removes; only the volume prunes destroy data and they say so.
- **No entitlements, no privileged helper.** The app is ad-hoc signed for local
  use; distributing it would need Developer ID signing + notarization.

## Icon credits

> **Before publishing:** the 39 PNGs in `Sources/Pier/Resources/icons/` are
> third-party **trademarks** (Docker, Anthropic, OpenAI, Cursor, JetBrains, …).
> They were converted for personal use. Redistributing them in a public
> repository is a licensing decision you should make deliberately — the safest
> options are to drop them and fall back to the built-in SF Symbols, or to keep
> only marks whose brand guidelines permit redistribution.

Harness brand icons are third-party trademarks, converted to 32px PNGs by
`scripts/convert-icons.sh` (point `PIER_ICON_SRC` at a directory of source
icons; the converted PNGs are checked in so the script is not needed to build).

Engine marks that aren't harnesses are vendored in `assets/vendor/` and
converted by the same script: Docker's whale (`assets/vendor/docker.svg` →
`icons/docker.png`) is a Docker, Inc. trademark, likewise bundled for personal
use. Apple's mark uses the `apple.logo` SF Symbol rather than a bundled file.

## Docs

- [CLAUDE.md](CLAUDE.md) — how to work in this repo: the probe-first
  verification pattern, and the traps this codebase already paid for.
- [docs/architecture.md](docs/architecture.md) — collection pipeline
  (lsof → ps → cmux/docker/container → attribution → sections → UI), file map,
  build/packaging notes.
- [docs/codexbar-practices.md](docs/codexbar-practices.md) — monitoring
  practices distilled from CodexBar, marked adopted / next / future.

Icons: `assets/icon.svg` (menu bar template) and `assets/app-icon.svg` are
rendered by `scripts/render-icons.sh` (auto-detects rsvg-convert, Chrome
headless, Playwright, or qlmanage); `scripts/build-app.sh` runs it
automatically when outputs are missing.
