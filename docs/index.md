# Pier documentation

Pier is a macOS menu bar app that connects listening ports and background
developer services to the agent harnesses and terminal sessions that started
them.

## Use Pier

- [Getting started](getting-started.md) — requirements, build, first launch, and
  the basic workflow.
- [Features and limitations](features.md) — ports, attribution, containers, MCP
  servers, previews, logs, events, and known limits.
- [Configuration](configuration.md) — optional cmux access, local preferences,
  and log locations.
- [Privacy and security](privacy-and-security.md) — what Pier reads, writes, and
  is allowed to connect to.
- [Troubleshooting](troubleshooting.md) — missing menu bar icon, unavailable
  integrations, logs, and reset steps.

## Build and contribute

- [Development and verification](development.md) — local toolchain, Make
  targets, fixture renders, live probes, and CI.
- [Architecture](architecture.md) — collection pipeline, attribution, code map,
  and deliberate constraints.
- [Contributing](../CONTRIBUTING.md) — contribution workflow and pull request
  expectations.
- [CodexBar design notes](research/codexbar-practices.md) — historical design research
  and decisions, not user documentation.

## Release readiness

Pier is MIT-licensed (see `LICENSE`) and currently builds as an ad-hoc signed
local app. A downloadable release still needs Developer ID signing and
notarization.
