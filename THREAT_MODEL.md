# Threat model

This document describes Pier's security boundaries, the threats considered by
the project, and the risks that remain. It complements the user-facing
[privacy and security contract](docs/privacy-and-security.md) and the
[vulnerability reporting policy](SECURITY.md).

## Scope

Pier is a macOS menu bar application running as the logged-in user. It:

- inventories listening ports and local processes with `lsof` and `ps`;
- optionally queries cmux, Docker, and Apple Containers;
- on request, reads one Terminal.app tab's scrollback through AppleScript;
- displays process, container, and in-memory log data;
- previews a user-selected local or LAN service in a `WKWebView`; and
- performs user-requested process, container, and prune actions.

This model covers the application source, its local subprocesses, its web
preview, its preferences, and `~/Library/Logs/Pier/pier.log`. Packaging and
distribution controls will need to be revisited before Pier ships a notarized
public build.

## Security goals

Pier should:

1. avoid sending inventory or usage data to an external service;
2. keep credentials out of process arguments and Pier's persistent log;
3. prevent untrusted names and tool output from becoming shell commands;
4. keep top-level preview navigation on the selected host or loopback;
5. make destructive actions explicit and user-initiated;
6. protect the persistent process inventory from other local user accounts; and
7. remain bounded when a subprocess hangs or produces errors.

Availability of the processes and containers that the user explicitly chooses
to stop is not a security goal.

## Assets

The assets requiring protection are:

- the cmux socket password;
- process command lines, which may contain credentials despite best practice;
- the inventory of local ports, processes, workspaces, containers, and MCP
  servers;
- container, cmux, and Terminal tab log content shown in the panel;
- the integrity and availability of the user's processes and containers;
- container images, caches, networks, and volumes affected by prune actions;
- the user's intent when starting, stopping, killing, or pruning resources; and
- the user's network privacy while previewing a service.

## Threat actors and untrusted inputs

Pier treats the following as potentially untrusted:

- any process listening on a discovered port, including an agent-started
  process;
- HTML, scripts, redirects, and subresources returned by a previewed service;
- process names, command lines, usernames, container names, log content, and
  all output from external tools;
- local Docker, Apple Containers, and cmux installations and their daemons;
- cmux configuration file contents; and
- a different, unprivileged local user account trying to read Pier's log.

A malicious process running as the same macOS user is partially in scope. Pier
must not unnecessarily expose secrets through globally visible arguments or
loose file permissions, but it cannot isolate data from an attacker that
already has the user's account privileges.

## Trust boundaries

### macOS process and filesystem boundary

Pier receives process metadata from operating-system tools and writes a small
amount of state to the user's home directory. The process table is not a secret
boundary: command-line arguments are visible to other local processes.

### External-tool boundary

Pier executes fixed binaries or discovered installed CLIs and parses their
output. Docker, Apple Containers, and cmux run outside Pier and may have greater
control over the user's workloads than Pier itself.

### Web-content boundary

Previewed pages execute as untrusted web content in WebKit. The navigation
delegate constrains top-level navigation, but the page remains active content
and can make subresource requests.

### User-action boundary

Read-only inventory crosses into mutation when the user requests a process kill,
container lifecycle operation, engine operation, or prune.

### Diagnostic-output boundary

`--print-*` probes intentionally print live machine data to the invoking
terminal. Their output inherits the terminal, shell history, redirection, and
CI capture policies chosen by the user.

## Threats and mitigations

### Command and argument injection

Threat: a crafted process or container name is interpreted as shell syntax and
causes arbitrary command execution.

Mitigations:

- `ProcessRunner` uses an executable URL and an argument array;
- Pier never invokes `sh -c` or interpolates values into a shell command; and
- subprocesses have explicit timeouts and are killed if they hang.

Residual risk: Pier trusts the installed executable at the resolved path to be
the intended CLI. A compromised CLI or writable installation path executes with
the user's privileges. Argument arrays prevent shell injection, but cannot make
a malicious external tool trustworthy.

### Secret disclosure through process inspection

Threat: the cmux password appears in `ps` output or a diagnostic process list.

Mitigations:

- the password is read only from cmux's configuration when needed;
- it is passed to the cmux child through `CMUX_SOCKET_PASSWORD`, never argv; and
- command arguments and environments are not written to Pier's log.

Residual risk: environment variables are not a secrecy boundary against the
same user, root, a debugger, or a compromised child process. Pier also reads and
may display command lines created by other programs; it cannot remove secrets
those programs placed in argv.

### Persistent inventory or credential leakage

Threat: Pier records sensitive process data or tool output in a world-readable
or unbounded file.

Mitigations:

- the log directory is mode `0700` and the log file is mode `0600`;
- existing permissions are tightened on the first write of each session;
- logs contain selected verbs, resource names, state changes, and bounded error
  summaries rather than command lines, environments, or raw scans;
- credential-shaped assignments are redacted as a backstop;
- error text is restricted to its first line and 200 characters;
- the log rotates at 512 KB and retains one previous file; and
- displayed container, cmux, and Terminal logs are bounded in memory and never
  persisted by Pier;
- Terminal scrollback is read only while its log drawer is open, by a fixed
  AppleScript that takes the tty as `argv`, and only after the user grants
  Automation permission.

Residual risk: resource names, event history, and sanitized error text can still
be sensitive. Redaction is heuristic and is not permission to log untrusted
secrets. Root and processes already running as the same user can generally read
or alter files in that user's home directory.

### Preview escape and unintended network access

Threat: a local service redirects the preview to an attacker-controlled site,
opens a dangerous URL scheme, or causes network traffic the user did not
expect.

Mitigations:

- previews are opened only after a user selects a discovered service;
- top-level HTTP and HTTPS navigation is limited to the selected host and
  loopback addresses;
- `file:`, `data:`, `javascript:`, and custom-scheme navigation is blocked; and
- the web view uses a non-persistent data store.

Residual risk: the navigation policy does not block remote scripts, images,
fonts, requests, popups, or every other subresource behavior of an allowed
page. Remote script loaded by a previewed page executes in that page's origin.
A hostile page may also attempt requests to other local or LAN services, subject
to WebKit's browser security rules. The preview is not a network sandbox and
must not be used where fully offline rendering is required.

### Destructive or unauthorized local actions

Threat: Pier kills the wrong process, mutates a container unexpectedly, or
deletes container data without informed consent.

Mitigations:

- actions originate from explicit UI controls;
- removing actions require confirmation and identify the affected resource;
- volume-prune confirmation explicitly states that data will be deleted;
- Pier has no privileged helper or special entitlement; and
- the operating system and container engine enforce the permissions of the
  logged-in user.

Residual risk: process inventory is a point-in-time snapshot. A process can exit
and macOS can reuse its PID before an action is delivered, so Pier cannot
provide a transactional guarantee that a PID still identifies the displayed
process. Attribution and grouping are usability signals, not authorization
decisions. A compromised container daemon can misrepresent an action or its
result.

### Spoofed inventory and misleading attribution

Threat: a process chooses a misleading name, command line, port, or ancestry so
that Pier labels it as a trusted harness or another workload.

Mitigations:

- attribution combines process ancestry, bounded token matching, executable
  paths, and optional cmux data;
- system binaries are identified by protected installation paths; and
- parsed data is displayed, not evaluated as code.

Residual risk: local inventory is observational and can be spoofed. Labels,
section placement, and activity ranking do not establish process identity or
trust.

### Denial of service

Threat: a tool hangs, emits excessive output, or repeatedly fails, blocking
Pier or consuming resources.

Mitigations:

- one monitor orchestrates bounded periodic queries;
- subprocesses have timeouts and a SIGKILL watchdog;
- stdout and stderr are drained concurrently to avoid pipe deadlock;
- displayed log streams and persistent logs are bounded; and
- optional integrations fail independently.

Residual risk: `ProcessRunner` captures subprocess output in memory without a
byte limit. A malicious or broken CLI can consume memory before its timeout.
Pier also depends on WebKit and the operating system to contain a resource-heavy
preview.

### Supply-chain and binary substitution

Threat: Pier executes a trojanized `docker`, `container`, or `cmux` binary.

Mitigations:

- system tools use absolute paths;
- optional CLIs prefer known installation paths; and
- Pier does not download or update external tools.

Residual risk: Pier does not currently verify code signatures or hashes for
optional CLIs. A binary installed or replaced at a resolved path is trusted
with Pier's user-level privileges.

## Assumptions

This model assumes:

- macOS process isolation, filesystem permissions, WebKit sandboxing, and code
  signing behave as documented;
- the user understands that Docker and Apple Containers control local
  workloads;
- the user does not place credentials in command-line arguments;
- the Pier source and build environment have not already been compromised; and
- physical access, root access, or full compromise of the logged-in account
  defeats Pier's local confidentiality controls.

## Out of scope

The following are outside Pier's security boundary:

- vulnerabilities in macOS, WebKit, Docker, Apple Containers, cmux, or a
  previewed service;
- isolation between Pier and another process already running as the same user;
- the security of containers, MCP servers, or development services themselves;
- secrets deliberately printed by diagnostic probes or shown in a selected log;
- network requests initiated by preview subresources; and
- availability after the user authorizes a stop, kill, or prune operation.

An out-of-scope dependency vulnerability may still require a Pier mitigation if
Pier can reasonably reduce its users' exposure.

## Security review triggers

Update this model and the privacy contract when a change:

- adds a network request, URL scheme, web-view capability, or persistent store;
- reads a new file, environment variable, process field, credential, or log;
- executes a new tool or changes binary resolution;
- adds an action that mutates processes, engines, containers, or data;
- changes confirmation behavior, log content, or file permissions;
- introduces a privileged helper, entitlement, updater, or distribution
  channel; or
- changes what a diagnostic probe prints.

Relevant controls should have pure tests where possible and a live probe where
the behavior crosses into processes, sockets, WebKit, or the filesystem.

## Reporting

Report suspected vulnerabilities privately using the instructions in
[`SECURITY.md`](SECURITY.md). Include the affected commit, reproduction steps,
impact, and any relevant logs after removing local process data and credentials.
