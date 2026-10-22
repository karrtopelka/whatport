# WhatPort

A native macOS menu bar utility that shows every development server listening on your Mac, which project it belongs to, and lets you stop, start and restart it. Built for the "an agent ran `bun run dev` three hours ago and never stopped it" problem.

- Swift 6 + SwiftUI, AppKit where needed. No Electron, no web views, no dependencies.
- Liquid Glass controls on macOS 26+, materials on macOS 15.
- No network access, telemetry, accounts or root. Ad-hoc signed: runs indefinitely without a developer account.

## Requirements

- macOS 15.0 or later (Apple Silicon and Intel).
- Xcode 16 or later to build (developed with Xcode 27.1 / Swift 6.4 on macOS 27).
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) if you edit `project.yml`. The generated `WhatPort.xcodeproj` is committed and usable as-is.

## Build and install

```sh
Scripts/build-install.sh               # Release build → ~/Applications/WhatPort.app, then launches it
Scripts/build-install.sh /Applications # install system-wide
Scripts/build-install.sh --build-only  # only produce dist/WhatPort.app
```

Or open `WhatPort.xcodeproj` in Xcode and run the `WhatPort` scheme. The app lives in the menu bar only (no Dock icon). Quit from the popover footer or ⌘Q while it is open.

The build is signed ad hoc (`CODE_SIGN_IDENTITY=-`) with the hardened runtime and **without** App Sandbox: a sandboxed app cannot inspect or signal other processes, which is the whole point of this tool.

## Using it

Click the network icon in the menu bar.

| Filter | Shows |
|---|---|
| **Dev** (⌘1) | Identified projects, dev runtimes (node, bun, python, …) and user-space binaries. Default. |
| **All** (⌘2) | Everything your user owns that listens on TCP. System services and unidentified processes are hidden unless enabled in Settings. |
| **Managed** (⌘3) | Projects with a saved launch configuration, running or not. |

Each row shows the project (or executable), framework/runtime, port chips (click to open in the browser, right-click to copy), PID and uptime, plus Open / Restart / Stop / More. Click a row for details: full process info, parent chain, project metadata, the suggested launch command, and captured output for instances WhatPort started.

Shortcuts: ⌘R refresh · ⌘F search · ⌘, settings · ⌘[ back · ⌘Q quit.

### Stopping

Stop asks for confirmation inline in the popover (configurable), then sends `SIGTERM` after verifying the PID still belongs to the same process (PID + start time). If a package-manager runner such as `npm run dev` or `bun run dev` is the parent of the listener and runs in the same project, it is stopped first so it cannot respawn the server. "Stop Listener Only" in the More menu signals just the listening process. If a process is still alive 3 seconds later the row offers **Force Stop** (`SIGKILL`), which always asks for confirmation. System processes are never signalled.

### Restarting

A PID does not tell you how a process was started, so WhatPort never pretends it does. For a discovered process it *infers* a launch command and shows it with a confidence level and the reason:

1. `npm_lifecycle_event` + `npm_config_user_agent` in the process environment (e.g. `bun run dev`) — high.
2. A package-manager / `cargo run` / `deno task` parent process's command line — high.
3. The process's own arguments (`python -m uvicorn …`, `node node_modules/.bin/vite --host` mapped to a package.json script) — medium.
4. A `dev`/`start` script in package.json — medium/low.

Nothing runs until you click **Save & Restart**, **Save**, or edit it. Saved configurations become *managed projects*: Start, Stop and Restart work from the popover and from Settings › Projects, and the configuration persists in `~/Library/Application Support/WhatPort/launch-configurations.json`.

Managed instances are launched with Foundation `Process` (argv, no shell), in the configured directory, with your login shell's PATH plus common tool directories (`~/.bun/bin`, nvm, volta, fnm, mise, asdf, Homebrew, …). Their output goes to a log file, so they survive WhatPort quitting and are re-adopted on relaunch. Starting refuses to proceed if an expected port is already taken by another process.

## How discovery works

1. **Listening sockets** — `proc_listpids` + `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` enumerate TCP sockets in `LISTEN` state in-process (what `lsof -iTCP -sTCP:LISTEN` does, without spawning). If that fails, `/usr/sbin/lsof -F` is parsed as a fallback. IPv4 and IPv6 bindings of the same port are merged.
2. **Process metadata** — `sysctl kern.proc.pid` (parent, uid, start time), `proc_pidpath`, `PROC_PIDVNODEPATHINFO` (cwd) and `KERN_PROCARGS2` (arguments + a short allow-list of environment keys). Fields macOS refuses are shown as "not accessible", never guessed.
3. **Project identification** — walks up from the cwd (or `INIT_CWD`, `npm_package_json`, script paths in argv) looking for `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `Package.swift`, `Gemfile`, `mix.exs`, `composer.json`, `deno.json`, `.git`. Frameworks come from dependencies and config files; package managers from lockfiles. Monorepo packages show "in <workspace>". Results are cached for two minutes. It never scans downwards.
4. **Categorization** — system (`/System`, `/usr/libexec`, root-owned), application (`/Applications`, app-bundled runtimes), development (identified project, dev runtime, user-space binary) or unidentified.

## Limitations

- **Only your own processes are visible.** macOS does not expose other users' sockets, arguments or working directories without root, and WhatPort never escalates. Root daemons (e.g. `sshd`) will not appear.
- Restart commands for processes started outside WhatPort are inferred. Review them.
- Output is captured only for instances WhatPort started; discovered processes keep logging wherever they were started.
- The app cannot tell whether a listener speaks HTTP or HTTPS; "Open" uses `http://`.
- After relaunch, adopted instances are monitored by scanning, not by a termination handler.

## Project layout

```
project.yml                 XcodeGen spec (generates WhatPort.xcodeproj)
Sources/CSystem             Module map exposing libproc/sysctl to Swift
Sources/WhatPort
  App/                      @main, AppDelegate, menu bar label
  Models/                   ListeningSocket, ProcessSnapshot, ProjectInfo, LaunchConfiguration, ManagedState (+ state machine)
  Services/Scanning         LibprocPortScanner, LsofPortScanner (+ parser), Subprocess
  Services/Inspection       SystemProcessInspector (libproc/sysctl), ProcArgsParser
  Services/Projects         ProjectIdentifier, ProjectRootLocator (cache), PortCategorizer, FileSystemReading
  Services/Lifecycle        ProcessTerminator, ManagedProcessRunner, LaunchInferenceEngine, ExecutableResolver
  Services/Persistence      JSONConfigurationStore, AppSettings
  State/                    DiscoveryService (actor), AppModel (@MainActor @Observable)
  Views/                    Popover, rows, details, settings, Liquid Glass helpers
Tests/WhatPortTests         Swift Testing suites (unit + integration + opt-in visual snapshots)
Scripts/                    build-install.sh, make-icon.swift
```

## Tests

```sh
xcodebuild -project WhatPort.xcodeproj -scheme WhatPort -destination 'platform=macOS' test
```

Unit suites cover the lsof parser, IPv4/IPv6 extraction and de-duplication, `KERN_PROCARGS2` parsing, project root/metadata detection (in-memory file system), launch inference, process identity and termination (fake signal sender), the managed state machine, persistence, shell-word splitting and executable resolution. The `Integration` suite starts a real `python3 -m http.server` inside a temporary project, verifies discovery, identification and graceful termination, then exercises the managed runner (start, conflict detection, restart, stop, log capture). It only ever signals processes it created.

Stop/start actions are logged to the unified log (`log show --predicate 'subsystem == "com.karrtopelka.whatport"' --last 10m`).

To render the UI to PNGs for review: `defaults write com.karrtopelka.whatport WhatPortSnapshotDir /some/dir`, run the tests, then `defaults delete com.karrtopelka.whatport WhatPortSnapshotDir`.

## Privacy and safety

No network calls, no telemetry, no accounts. Only seven environment keys (`npm_lifecycle_event`, `npm_config_user_agent`, `npm_execpath`, `INIT_CWD`, `npm_package_json`, `VIRTUAL_ENV`, `PORT`) are read from other processes; nothing else from their environment is retained. Discovered command lines are displayed and used to *propose* argv arrays; they are never passed to a shell. Signals are sent only after identity verification, and only to your own processes.

## Credits

Named "whatport"; the original brief also refers to it as "Portside". Icon rendered by `Scripts/make-icon.swift`.
