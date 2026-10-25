# Features and limitations

## Ports and attribution

Pier reads listening TCP and UDP sockets with `lsof`, merges duplicate bind
addresses, and shows one entry per process, port, and protocol.

For each listener, Pier walks the process ancestry and combines two signals:

- known developer tools and AI agent harnesses, including Claude Code, Codex,
  Cursor, Kimi, OpenCode, terminal apps, and others defined in
  `Attributor.harnessTable`;
- cmux process, surface, and workspace mappings when cmux access is available.

The process itself wins before its launcher. This prevents a helper launched by
an agent from being mislabeled as the launcher when Pier recognizes the helper.
System services are separated from user development work.

## Search, scopes, and sorting

Search matches ports, process names, harnesses, and workspaces. Scope chips
filter All, Web, Ports, Containers, or MCP entries. Sections can be collapsed,
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
selected host and loopback addresses over HTTP or HTTPS; redirects to external
hosts and `file:`, `data:`, or `javascript:` URLs are blocked.

The navigation policy covers page navigation, not every subresource. A previewed
page can still load remote scripts, images, fonts, or other assets it references.

## Logs

Available log behavior depends on the source:

| Source | Behavior |
| --- | --- |
| Docker container | Live `docker logs --follow` stream |
| Apple container | `container logs` snapshot every 2 seconds |
| cmux-attributed process | Surface scrollback snapshot every 2 seconds |
| MCP server | Unavailable; stdio belongs to its harness |
| Plain local process | Use the terminal that launched it |
| System process | Use Console.app |

Log drawers keep a bounded in-memory line history and are never persisted by
Pier.

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
