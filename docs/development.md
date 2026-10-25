# Development and verification

Pier is a Swift Package Manager executable with SwiftUI hosted in AppKit. It
targets macOS 13+, has no Xcode project, and has no third-party Swift
dependencies.

## Toolchain

- macOS 13 or later
- Xcode 16 or later
- Xcode Command Line Tools selected with `xcode-select`

Check the environment:

```sh
swift --version
xcodebuild -version
xcrun swift-format --version
```

## Main commands

```sh
make            # list all targets
make build      # assemble and ad-hoc sign dist/Pier.app
make run        # rebuild, stop the old process, and relaunch
make test       # run the headless unit suite
make lint       # strict swift-format check
make fmt        # format Swift sources in place
make check      # lint and test
make clean      # remove SPM and app build products
```

Use `make run` for UI work so the launched bundle always contains the current
binary and resources. `swift build` alone does not update `dist/Pier.app`.

## Architecture

Read [Architecture](architecture.md) before changing collection or attribution.
The core pattern is:

- parsers and policies are pure functions over captured real output;
- `PortMonitor` owns polling and orchestration;
- views present state and dispatch actions;
- optional sources fail independently and explain their state.

When adding a parser, add a test containing representative real CLI output.

## Fixture renders

Fixture renders exercise panel layout without opening the live menu bar:

```sh
make fixture
```

The command writes variants to `/tmp/pier*.png`, including the normal list,
expanded preview and logs, engine states, events, and minimum-width panel.

A fixture proves layout only. It substitutes static content for the web view,
processes, sockets, and log tailers.

When changing UI structure, render before and after and compare every variant.
The minimum-width fixture catches controls that fit at the default width but wrap
at 340 points.

The README screenshot, `docs/images/pier-panel.png`, is the default list fixture.
After a visible UI change, regenerate it with
`swift build && .build/debug/Pier --render-fixture docs/images/pier-panel.png`.
Never replace it with a capture of a real panel: that shows your own processes,
paths and project names.

## Live probes

Use the matching probe whenever a change touches a live integration:

| Command | Purpose | Side effects |
| --- | --- | --- |
| `--print-groups` | Exact sections and attributed port rows | Read-only |
| `make activity` | Docker, Apple Containers, and MCP snapshot | Read-only |
| `make docker` | Docker state and reclaimable space | Read-only |
| `make apple` | Apple `container` state and reclaimable space | Read-only |
| `make cmux` | cmux discovery and socket access | Read-only |
| `make menubar` | Menu bar visibility by display | Read-only |
| `make anchor` | Panel placement relative to the status item | Opens the panel |
| `--probe-panel-stable` | Confirm the open panel does not move itself | Opens the panel |
| `--probe-resize` | Exercise real panel resizing | Opens and resizes the panel |
| `--probe-resize-perf` | Resize timing distribution | Persists panel size |
| `make viewport URL=…` | Real web preview CSS viewport | Connects to the supplied URL |
| `make logs C=…` | Live Docker log streaming | Reads a running container |
| `make selfevent` | Verify Pier actions are attributed to `you` | Spawns and kills a listener |
| `make statusitem` | Saved status-item repair state | Read-only |
| `make applog` | Pier's recent local log | Read-only |

Reset the panel size after a resize performance probe:

```sh
defaults delete com.hermosalabs.pier panelWidth panelHeight
```

Do not run a probe that could unexpectedly trigger authentication, Keychain, or
permission UI. Keep such behavior behind an explicit user action.

## Packaging

`scripts/build-app.sh`:

1. builds the selected SPM configuration;
2. assembles `dist/Pier.app`;
3. copies the SPM resource bundle and `Pier.icns`;
4. ad-hoc signs the app.

Verify a local bundle:

```sh
make build
codesign --verify --verbose dist/Pier.app
test -f dist/Pier.app/Contents/MacOS/Pier
test -f dist/Pier.app/Contents/Info.plist
```

The app is not currently Developer ID signed or notarized.

## Icons

Source artwork:

- `assets/icon.svg` — monochrome menu bar template;
- `assets/app-icon.svg` — full-color app icon.

Normal builds use committed render outputs. Maintainers can regenerate them with
`scripts/render-icons.sh`; see [Configuration](configuration.md#icon-rendering).

The harness and vendor icons under `Sources/Pier/Resources/icons/` are
third-party marks. Do not treat their presence as redistribution permission.

## Continuous integration

`.github/workflows/ci.yml` runs strict formatting, app bundle assembly, tests,
and bundle verification on a macOS runner. Keep the Makefile as the shared
source of truth instead of duplicating command logic in the workflow.

Docs-only changes currently skip CI to avoid macOS runner cost. If the repository
later requires the CI check through branch protection, add an always-running
lightweight path so docs-only pull requests are not left with a missing required
check.

## Before handing off a change

```sh
make check
make build
codesign --verify --verbose dist/Pier.app
```

Also run the relevant fixture or live probe for the subsystem you changed.
