# Getting started

Pier runs in the macOS menu bar and has no Dock icon. It is currently distributed
as a source build.

## Requirements

- macOS 13 or later
- Xcode 26 or later, including the Command Line Tools
- Git and Make

Pier has no third-party Swift dependencies. These integrations are optional:

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- Apple [`container`](https://github.com/apple/container)
- [cmux](https://github.com/manaflow-ai/cmux)

Missing integrations do not prevent Pier from starting.

## Build and launch

```sh
git clone https://github.com/shaaaaawn/pier.git
cd pier
make build
open dist/Pier.app
```

`make build` compiles the Swift package, assembles `dist/Pier.app`, copies its
resources, and ad-hoc signs the bundle. This is a local development build, not a
notarized release.

For subsequent launches:

```sh
make run
```

This rebuilds Pier, stops an existing Pier process, and opens the new app bundle.

## First launch

Look for the pier glyph in the menu bar and select it to open the panel. Hover
it for the listening-port count. A plain `•` beside it means there are start or
stop events you haven't seen; an orange or red `●` means macOS reports memory
pressure. If the icon is hidden by a crowded menu bar, open Pier again from
Spotlight or Finder and the panel appears anyway.

From the panel you can:

1. search by port, process, harness, or workspace;
2. switch between All, Dev, Ports, Containers, and MCP scopes — Dev lists only
   the dev servers you're running, by project;
3. expand a supported row to preview a local web app or view logs;
4. hover a row for process details and available actions;
5. open the event feed to see recently started or stopped work.

Pier refreshes every 5 seconds while the panel is open and every 30 seconds in
the background.

## Optional integrations

Docker and Apple `container` sections appear when their CLIs are installed. Pier
shows whether an engine is ready, stopped, or failing and only offers actions
that match that state.

cmux attribution works without configuration when Pier is allowed to access the
cmux socket. If workspace names do not appear, follow
[Enable cmux attribution](configuration.md#enable-cmux-attribution).

## Verify the checkout

```sh
make check
make build
codesign --verify --verbose dist/Pier.app
```

`make check` runs strict Swift formatting checks and the headless unit suite.

## Next steps

- Read [Features and limitations](features.md) for the complete behavior.
- Use [Troubleshooting](troubleshooting.md) if Pier launches without a visible
  menu bar item.
- Read [Development and verification](development.md) before changing code.
