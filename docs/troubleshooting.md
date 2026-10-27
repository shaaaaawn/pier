# Troubleshooting

## Pier is running but the menu bar icon is missing

Several unrelated macOS states produce the same symptom. Pier repairs the
recoverable cases at launch:

| Cause | Pier's response |
| --- | --- |
| App Nap drops a windowless app's status item | Holds a lifetime activity assertion |
| Persisted `NSStatusItem VisibleCC` is false | Clears stale visibility once |
| Persisted preferred position is off-screen | Clears it before creating the item |
| macOS force-hides the item | Detects and logs the state |

Whatever the cause, **open Pier again** — from Spotlight, Finder, or
`open dist/Pier.app` — and the panel appears at the top right of the screen,
icon or no icon. From there, ⌘-drag the icon somewhere visible once it shows.

Inspect the relevant saved state without changing it:

```sh
make statusitem
```

Then rebuild and relaunch:

```sh
make run
```

## The panel has a gap below an auto-hidden menu bar

In a fullscreen space or with automatic menu bar hiding enabled, macOS reveals
the bar only while the pointer is near the top edge. A custom panel cannot keep
it visible.

Pier anchors the panel once when it opens and keeps it still. This avoids the
panel jumping whenever the menu bar hides or appears. The gap is expected while
the bar is hidden.

Diagnostics:

```sh
make menubar
make anchor
```

Both commands are read-only.

## cmux workspaces do not appear

Run:

```sh
make cmux
```

The report distinguishes a missing CLI, denied socket access, and malformed
configuration. If access is denied, follow
[Enable cmux attribution](configuration.md#enable-cmux-attribution).

Make sure you edited a real `automation` object, not the commented example in
cmux's default JSONC file.

## Docker or Apple Containers shows unavailable

Check the engines independently:

```sh
make docker
make apple
```

Pier distinguishes:

- **CLI missing** — install the optional tool;
- **not running** — start is a valid action;
- **failing** — the engine answered but returned an error; starting it again may
  not fix the underlying fault.

The probes never start, stop, or prune an engine.

## A stopped container is missing

Pier asks both engines for running and stopped workloads. Verify the CLI itself:

```sh
docker ps -a
container list --all
```

If the CLI shows the workload and Pier does not, run `make activity` and include
its relevant, non-sensitive output in a bug report.

## A preview does not load

Confirm the service is reachable in your normal browser, then verify the CSS
viewport path:

```sh
make viewport URL=http://127.0.0.1:3000
```

Pier blocks redirects away from the selected host. A service that redirects to
an external login or asset host may work in a browser while Pier intentionally
refuses that navigation.

## Logs are unavailable

Log support depends on the row type:

- Docker provides a live stream;
- Apple `container` and cmux provide periodically refreshed snapshots;
- MCP stdio belongs to its harness;
- ordinary processes keep output in the terminal that launched them.

See [Logs](features.md#logs) for the complete matrix.

## Reset the panel size

Double-click the corner resize grip, or run:

```sh
defaults delete com.hermosalabs.pier panelWidth panelHeight
```

## Inspect Pier's own log

```sh
make applog
make applog N=200
make applog-follow
```

Before sharing logs, review them for local service and container names. Pier does
not persist command lines or environment variables.
