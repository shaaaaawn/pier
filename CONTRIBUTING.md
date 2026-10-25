# Contributing to Pier

Thanks for helping make Pier easier to use and maintain.

Pier is a macOS app with behavior that crosses AppKit, local processes, sockets,
and optional CLIs. Contributions should be small, testable, and verified against
the real path they change.

## Before you start

1. Read the [documentation index](docs/index.md).
2. Read [Architecture](docs/architecture.md) for data-flow changes.
3. Read [Development and verification](docs/development.md) for commands,
   fixtures, and probes.
4. Open an issue before a large feature or architectural change so the approach
   can be discussed before implementation.

## Set up

```sh
git clone https://github.com/shaaaaawn/pier.git
cd pier
make check
make build
```

Pier requires macOS 13+ and Xcode 16+.

## Make a change

- Keep changes focused; avoid unrelated refactors.
- Put parsing and policy logic in pure, testable functions rather than views.
- Add captured real CLI output to parser tests.
- Treat every external tool as optional and explain unavailable states.
- Preserve the privacy and security constraints in
  [Privacy and security](docs/privacy-and-security.md).
- Confirm destructive actions and state exactly what they remove.

For UI changes, run `make fixture` and inspect every relevant variant, including
the minimum-width render. For process, socket, container, or web view changes,
run the corresponding live probe from
[Development and verification](docs/development.md#live-probes).

## Validate

At minimum:

```sh
make check
make build
codesign --verify --verbose dist/Pier.app
```

Include the additional fixtures and probes you ran in the pull request.

## Pull requests

Keep each pull request reviewable and explain:

- the problem being solved;
- the chosen approach and important trade-offs;
- how the change was verified;
- any user-visible, privacy, or destructive-action impact.

Do not include third-party brand assets without confirming that their license or
brand guidelines allow redistribution.

## Security issues

Do not open a public issue for a vulnerability. Follow
[`SECURITY.md`](SECURITY.md) instead.
