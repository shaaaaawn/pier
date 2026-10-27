# Privacy and security

Pier inspects local process, port, and container information. The rules in this
document are product constraints, not marketing claims.

## Network access

Pier makes no telemetry, analytics, update-check, or background service API
requests.

User-selected previews load a local or LAN URL in a `WKWebView`. The web view
uses a non-persistent data store, so previewed services do not leave cookies,
local storage, or caches in Pier.

Top-level preview navigation is restricted to the selected host and loopback
addresses over HTTP or HTTPS. External redirects and `file:`, `data:`, and
`javascript:` navigations are blocked.

This navigation policy does not intercept every page subresource. A previewed
page can still request remote scripts, images, fonts, or other assets that it
references. Do not use the preview for a page if its subresource traffic must
remain fully offline.

## Local data Pier reads

Pier performs bounded local queries:

- `lsof` for listening TCP and UDP sockets;
- `ps` for process ancestry, CPU, memory, users, and command lines;
- optionally, `cmux top` for workspace and surface attribution;
- `proc_pidinfo` for the tty and working directory of a Ghostty or Terminal
  tab's shell, to group its ports by tab;
- `proc_pidinfo` for the working directory of a listening process, then the
  nearest project marker above it (`package.json`, `pyproject.toml`, `.git`, …)
  and the `name` field of its `package.json` (first 64 KB only), to name dev
  servers. Only directories under your home folder are read. Pier never sends
  requests to listening ports to identify them;
- only when you open the logs for a port in a Terminal.app tab, that tab's
  scrollback, through `osascript` and Terminal's AppleScript `history`. macOS
  asks for Automation permission the first time;
- optionally, Docker and Apple `container` commands for engine and workload
  state.

This data remains in memory except for the intentionally limited application log
described below.

Full process command lines can contain secrets. Pier uses them for attribution
and may display them in a tooltip or `--print-*` diagnostic output. Do not put
credentials in command-line arguments.

## Local data Pier writes

Pier writes only:

1. interface preferences in macOS `UserDefaults`; and
2. its rotating application log at `~/Library/Logs/Pier/pier.log`.

The log directory uses mode `0700`; the log file uses mode `0600`. Pier records
launches, engine state transitions, actions, and start/stop events. It does not
record full command lines, environment variables, or raw process scans.

Failure text is limited to its first line, capped at 200 characters, and passed
through credential-shaped value redaction.

Container, cmux, and Terminal logs shown in the panel are bounded in memory and
are never written by Pier.

Terminal scrollback is whatever the tab printed, which can include secrets a
command echoed. Pier reads it only while that row's log drawer is open, never on
the refresh timer, and never for a tab you haven't opened. The AppleScript is
fixed text; the tty is passed as an argument, not spliced into the script. You
can revoke access in System Settings → Privacy & Security → Automation.

## Process execution

Pier launches tools with executable and argument arrays. It does not invoke
`sh -c`, so names read from process or container output cannot become shell
syntax.

Secrets do not enter process arguments. A cmux socket password is passed through
the child environment because command-line arguments are visible in the process
table.

## Destructive actions

Pier can terminate processes, stop containers, and prune container resources.
These actions are user-initiated. Removing actions require confirmation and
identify what will be removed; volume-prune confirmations explicitly state that
data will be deleted.

## Privileges and signing

Pier has no privileged helper and requests no special entitlements. Local builds
are ad-hoc signed. Public downloadable builds will require Developer ID signing
and notarization.

## Reporting a vulnerability

Follow the private reporting instructions in [`SECURITY.md`](../SECURITY.md).
Do not open a public issue for a vulnerability that could expose local process
data or enable unintended command execution.
