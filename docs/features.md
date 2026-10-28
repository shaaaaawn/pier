# Features and limitations

## Ports and attribution

Pier reads listening TCP and UDP sockets with `lsof`, merges duplicate bind
addresses, and shows one entry per process, port, and protocol.

For each listener, Pier walks the process ancestry and combines two signals:

- known developer tools and AI agent harnesses, including Claude Code, Codex,
  Cursor, Kimi, OpenCode, terminal apps, and others defined in
  `Attributor.harnessTable`;
- cmux process, surface, and workspace mappings when cmux access is available;
- the Ghostty or Terminal tab a process runs in, grouped by the tab's working
  directory ("Ghostty · ~/code/web"). Pier reads the tab shell's tty and working
  directory in-process with libproc; no permission is needed. An agent nearer
  the process still wins: Claude Code run in a Ghostty tab stays "Claude Code".

**Dev servers** are named for what they are — "Angular · storefront",
"Wrangler · api", "Vite · site" — instead of their runtime (`node`), and the
**Dev** scope lists only them, grouped by project. Detection is local and
passive, in three layers:

1. Rule out noise: system binaries, anything inside an app bundle (browsers,
   Google Drive, editor helpers), browsers with a remote-debugging port, MCP
   servers, agent harnesses' own sockets, and local services such as adb or
   databases.
2. Rule out a dev tool's plumbing: `--inspect` / `--inspector-addr` debugger
   ports, and every workerd port except its `entry` socket (Wrangler's own
   proxy included).
3. Name what's left from its command line (Angular, Next.js, Vite, Wrangler,
   Rails, Django, … — about 35 signatures), else count a runtime running a
   script (`node server.mjs`, `python -m …`) when it runs in a project under
   your home folder. The project is the nearest `package.json` / `pyproject.toml`
   / `.git` above its working directory, named by `package.json`'s `name`.

The process itself wins before its launcher. This prevents a helper launched by
an agent from being mislabeled as the launcher when Pier recognizes the helper.
System services are separated from user development work.

## Search, scopes, and sorting

Search matches ports, process names, harnesses, and workspaces. Scope chips
filter All, Dev, Ports, Containers, or MCP entries. Sections can be collapsed,
and system processes can be hidden.

Available sort orders:

- **Activity** — likely web servers and recently busy processes first;
- **Port** — ascending port;
- **Name** — alphabetical process name.

Activity uses a recent CPU peak rather than a single sample so idle dev servers
do not constantly jump around the list.

## Row actions

Depending on the row, Pier can:

- open a localhost URL in the default browser;
- copy `localhost:<port>`;
- show a local web preview;
- show available logs;
- start or stop a container;
- terminate a process with SIGTERM, then offer SIGKILL if it survives.

Actions that remove data, including volume prunes, require explicit confirmation
and state what will be removed.

## Containers

Pier supports Docker and Apple's `container` CLI as separate sibling sections.
It shows running and stopped containers, published ports, status, images, and
engine health.

Engine menus expose only commands supported by that CLI:

| Capability | Docker | Apple `container` |
| --- | --- | --- |
| Start and stop services | Yes | Yes |
| Restart engine | Yes | No upstream command |
| Aggregate prune | Yes | No upstream command |
| Resource-specific prune | Yes | Yes |
| Reclaimable-space summary | Yes | Yes |

Pier derives health from real API-backed commands rather than trusting a desktop
status command alone.

## MCP servers

MCP server processes are detected from the process table, grouped by label, and
attributed to their harness or cmux surface when possible. Multiple identical
servers appear as one row with a count.

MCP stdio belongs to the harness that launched it, so Pier cannot tail MCP logs
directly.

## Web previews

Browsable rows can open an inline `WKWebView`. Pier gives the page a desktop-sized
CSS viewport and scales it to the panel instead of forcing the page into a mobile
layout.

The preview uses a non-persistent data store. Navigation is limited to the
selected URL: the selected host over HTTP or HTTPS, and on loopback the selected
**port** as well — `localhost` names hundreds of unrelated services, and the
untrusted previewed page doesn't get to pick a different one. Redirects to
external hosts, other local ports, and `file:`, `data:`, or `javascript:` URLs
are blocked.

The navigation policy covers page navigation, not every subresource. A previewed
page can still load remote scripts, images, fonts, or other assets it references.

## Logs

Available log behavior depends on the source:

| Source | Behavior |
| --- | --- |
| Docker container | Live `docker logs --follow` stream |
| Apple container | `container logs` snapshot every 2 seconds |
| cmux-attributed process | Surface scrollback snapshot every 2 seconds |
| Terminal.app tab | Tab scrollback via AppleScript every 2 seconds, while the drawer is open; needs Automation permission |
| Ghostty tab | Unavailable; Ghostty 1.3 doesn't expose a tab's output to other apps |
| MCP server | Unavailable; stdio belongs to its harness |
| Plain local process | Use the terminal that launched it |
| System process | Use Console.app |

Log drawers keep a bounded in-memory line history and are never persisted by
Pier.

## Settings

Open Settings with the gear in the panel header or ⌘, while the panel is open:

- **Open Pier at login** — via macOS's login items; the toggle shows macOS's own
  status, including "waiting for approval".
- **Keyboard shortcut** — opens the panel from any app, even when a crowded menu
  bar or the notch hides the icon. Default ⌃⌥P; record another or clear it. If
  another app already owns the combination, Settings says so.
- **Hidden ports** — right-click a port → Hide, or add ports in Settings. Hidden
  ports keep running; Pier leaves them out of the list, counts and event feed.

## System glance

The footer shows, left to right:

- **Memory** — used / total RAM and swap, in the memory-pressure colour.
- **Heat** — a thermometer in macOS's thermal-state colour, the CPU temperature,
  and whole-machine CPU load. Each value sits on a small line: a fixed scale
  (temperature 30–105 °C; CPU 0–100%, where 100% means every core is busy), a
  band for its low–high over the last 30 minutes, and a dot for now. The
  tooltip adds the hottest core, the GPU, fan speeds, and the three busiest
  processes (in Activity Monitor's "% of one core", so up to 100% × cores).
- **Disk** — free space on the startup volume.

Temperatures come from the Mac's System Management Controller and are
descriptive only — "hot" (the colour, the menu bar dot) is macOS's own thermal
state. On a Mac whose sensors Pier doesn't recognise, the temperature is
omitted and CPU is shown alone. Verified on an M1 Max.

The footer narrows gracefully: lines, then numbers, then the temperature alone,
then the coloured thermometer.

## Start and stop events

Pier diffs consecutive refreshes to record:

- ports appearing or disappearing;
- containers switching between running and stopped;
- MCP groups appearing, disappearing, or changing count.

Actions taken through Pier are labeled `you`. A cold launch seeds the baseline
without treating everything already running as new.

This is polling, not a system event stream. A process that starts and exits
between refreshes may never be observed.

## Local app log

Pier records launches, engine state transitions, actions, and detected start/stop
events in `~/Library/Logs/Pier/pier.log`. It does not log process command lines,
environment variables, or raw scan output. See
[Privacy and security](privacy-and-security.md).
