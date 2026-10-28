# Configuration

Pier works without a configuration file. UI choices are stored in macOS
`UserDefaults`, and optional integrations are discovered from installed CLIs.

## Enable cmux attribution

Pier uses `cmux top` to connect listening processes to cmux workspaces and
surfaces. cmux defaults to allowing only processes started inside cmux to access
its socket, which can exclude Pier.

Add an active `automation` block to `~/.config/cmux/cmux.json`:

```jsonc
{
  "automation": {
    "socketControlMode": "allowAll",
    "socketPassword": "<a long random string>"
  }
}
```

The password is optional. When present, Pier reads it from the cmux configuration
and passes it to the child process through `CMUX_SOCKET_PASSWORD`, never as a
command-line argument.

cmux's default config contains a large commented example. Editing a setting
inside that commented block has no effect. Add or update the real top-level
`automation` object.

Check access without changing anything:

```sh
make cmux
```

cmux applies the setting on the next connection; a restart is normally
unnecessary.

## Stored preferences

Pier stores interface state under the `com.hermosalabs.pier` defaults domain,
including:

- panel width and height;
- selected scope and sort mode;
- hidden-system and collapsed-section state;
- preview viewport width.

Reset the persisted panel size:

```sh
defaults delete com.hermosalabs.pier panelWidth panelHeight
```

You can also double-click the panel's corner resize grip to restore its default
size.

## Local logs

Pier's rotating application log lives at:

```text
~/Library/Logs/Pier/pier.log
~/Library/Logs/Pier/pier.log.1
```

Useful commands:

```sh
make applog          # last 50 lines
make applog N=200    # choose a line count
make applog-follow   # follow new entries
```

The log directory is created with mode `0700` and the log file with mode `0600`.
See [Privacy and security](privacy-and-security.md) for what is and is not
recorded.

## Icon rendering

The rendered app icon (`assets/Pier.icns`) is checked in, so normal builds
need no SVG toolchain. The menu bar glyph is drawn in code and needs nothing.

Maintainers can regenerate them with:

```sh
./scripts/render-icons.sh
```

The script uses the first available renderer: `rsvg-convert`, Google Chrome,
Playwright configured through `PIER_PLAYWRIGHT_NODE_MODULES`, or `qlmanage`.

Agent, terminal and Docker icons are not rendered or bundled: Pier reads them
from the apps installed on the Mac at runtime.
