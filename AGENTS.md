# AGENTS.md

Instructions for coding agents (Claude Code and others) that install, update or work on
**Pomodoro**, a macOS pomodoro timer that lives in the MacBook notch. The app's UI is in
Spanish; talk to the user in their language.

## Install it for the user

Requirements: macOS 15 (Sequoia) or later, Apple Silicon or Intel.

Preferred: build from source. A locally built app isn't quarantined, so macOS doesn't
block the first launch.

1. Check for the command line tools: `xcode-select -p`. If that fails, run
   `xcode-select --install`, ask the user to finish the installer window, and wait.
2. Clone the repo where the user keeps code (default `~/notch-pomodoro`):
   `git clone https://github.com/ignaciobernardo/notch-pomodoro ~/notch-pomodoro`
3. `cd ~/notch-pomodoro && ./build.sh install`. This builds a universal app, copies it to
   `~/Applications/Pomodoro.app` and launches it. It takes about a minute.
4. Confirm with `pgrep -lx Pomodoro`. Then tell the user:
   - Hover the notch to open it, and press the white play button to start.
   - Right-click the notch for settings.

Alternative: `brew install --cask ignaciobernardo/tap/pomodoro`. The app isn't notarized,
so the first launch must be approved in System Settings → Privacy & Security →
Open Anyway. Don't strip the quarantine attribute yourself unless the user asks.

## Update it

- The app checks GitHub Releases once a day. When there's a new version the notch shows
  "versión X disponible · actualizar" and installs it in one click. Right-click →
  "buscar actualizaciones" checks right away. Every update zip is verified against an
  Ed25519 key built into the app.
- From source: `git pull && ./build.sh install`. Via Homebrew: `brew upgrade --cask pomodoro`.
- Reinstalling restarts the app. A running session survives the restart because its state
  is saved, but ask before restarting in the middle of someone's pomodoro.

## What the user will be asked

- **Local network:** the first time they use "juntos" (pomodoros with people nearby).
  Without it, Macs can't find each other.
- **Calendar:** only if they turn on right-click → calendario.
- The app is ad-hoc signed, so macOS may ask again for these permissions after an update.

## Where things live

| What | Where |
| --- | --- |
| Session log | `~/Documents/pomodoros.md`. Change it with `defaults write cl.natochi.notch-pomodoro logPath "~/path.md"` |
| Settings and saved state | `defaults read cl.natochi.notch-pomodoro` (don't delete it while a session runs) |
| App | `~/Applications/Pomodoro.app` (source build) or `/Applications/Pomodoro.app` (brew) |

To uninstall: right-click the notch → salir, then delete the app.

## Working on the code

Native AppKit + SwiftUI, built with `swiftc` alone. No Xcode project, no dependencies.

| File | What it does |
| --- | --- |
| `Sources/main.swift` | Notch window and its placement, hover, toasts, right-click menu, wiring |
| `Sources/NotchView.swift` | Every visual state: idle, live wings, expanded, toast; notch silhouette and springs |
| `Sources/Pomodoro.swift` | The timer, phases and cycle, persistence, sync snapshot/adopt |
| `Sources/MarkdownLog.swift` | Appends sessions to the `.md` log with per-day totals |
| `Sources/Together.swift` | "juntos": MultipeerConnectivity group of up to 8 Macs |
| `Sources/CalendarSync.swift` | Optional EventKit events for finished focus sessions |
| `Sources/Updater.swift`, `Sources/UpdateKey.swift` | Self-update from GitHub Releases with signature check |
| `Sources/Snapshot.swift` | Debug renders of each state (`POMO_SNAPSHOT`) |

**Hard rule: it must cost almost nothing to run.** Idle is 0% CPU with no timers. Running is
about 0.2% CPU with one wakeup per second. Keep it that way:

- Don't poll the mouse. Hover comes from one `NSTrackingArea` on a window sized to the notch.
- Don't run timers when nothing is running. Timers carry a `tolerance`.
- Don't animate continuously while collapsed.
- Sync messages go out only when someone presses something.

Check:

- Build: `./build.sh` (output in `build/`).
- Logic tests:
  `swiftc -swift-version 5 Sources/Pomodoro.swift Sources/MarkdownLog.swift Sources/Together.swift Sources/Updater.swift Sources/UpdateKey.swift tests/main.swift -o build/logic-test && build/logic-test`
- Fast timers: `POMO_FAST=1` (minutes become seconds). Use `POMO_LOG=/tmp/x.md` to keep the real log clean.
- Renders without touching the user's running app. Make a copy with another bundle id, so it
  doesn't share saved state (the window stays invisible):
  `cp -R build/Pomodoro.app /tmp/snap.app && plutil -replace CFBundleIdentifier -string cl.natochi.notch-pomodoro.snapshot /tmp/snap.app/Contents/Info.plist && codesign -fs - /tmp/snap.app && POMO_SNAPSHOT=/tmp/snaps POMO_LOG=/tmp/snaps/x.md /tmp/snap.app/Contents/MacOS/Pomodoro`
- Never run the real bundle id in debug modes, or `defaults delete` its domain, while the
  user has a session going.

## Releasing (maintainer only)

`./release.sh <version> "<notes>"`. It builds, signs the zip with the private key at
`~/.config/notch-pomodoro/release-ed25519.key`, tags, publishes the GitHub release, and bumps
the cask in `ignaciobernardo/homebrew-tap`.

- Never commit the private key.
- Without it, nobody else can publish updates that installed apps accept. That is intended.
