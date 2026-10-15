# prism-tui — Prism for the terminal

A cross-platform terminal UI for managing isolated [Cursor](https://cursor.sh)
and Claude Code profiles (plus the built-in Main Claude Desktop). Same profile
dirs as the macOS, Windows and Linux apps — no app required:

- Cursor: `~/.cursor_profiles/.profiles.json`
- Claude Code: `~/.claude_code_profiles/.profiles.json`
- Claude Desktop: `~/.claude_desktop_profiles/.profiles.json`

```
▲ Prism v1.2.3                              ● 1 running · 372.6 MB live
 2 profiles · 1 running · / to filter

▸ M  Main Cursor [BUILT-IN]  ● Running · PID 12214 · ~/code/agents · 372.6 MB / 16 GB limit
     Memory ████░░░░░░
   M  Mojo Layers  ○ Idle · 16 GB limit
     Memory ░░░░░░░░░░

 CPU 12% · RAM 372.6 MB / 34.4 GB · 2 profiles
 / filter · enter launch · x stop · n new · d delete · R rescan · q quit
```

## Install

```bash
npm i -g prism-tui          # Node users
pipx install prism-tui      # Python users
brew install --cask moderniselife/prism/prism-tui
winget install ModerniseLife.PrismTUI
```

Or grab a static binary from
[GitHub releases](https://github.com/moderniselife/prism/releases) — no
runtime needed anywhere.

## Keys

| Key | Action |
|-----|--------|
| `↑↓` / `k j` | Move selection |
| `/` then type | Filter profiles (`esc` clears) |
| `enter` | Launch (opens a new window when already running) |
| `x` | Stop the selected profile |
| `n` | New profile (`tab` moves fields, `space` switches app, `enter` advances/saves, `esc` cancels) |
| `d d` | Delete (press twice; moves the folder to `.trash/`) |
| `R` | Rescan profiles from disk |
| `q` / `ctrl+c` | Quit |

## Notes

- Every number is measured live (process RSS, on-screen status, kernel CPU).
  CPU shows `—` until the second sample; RAM shows `—` when unreadable.
- Claude Code profiles are terminal sessions, not GUI apps: `enter` prepares
  the profile's `CLAUDE_CONFIG_DIR` and prints the exact `claude` command to
  run (first run walks through login for that account). They never report
  "running".
- Claude Desktop profiles launch with `--user-data-dir=<profile>`: separate
  login, several at once. On Windows this needs the standalone installer build
  (the Store build drops launch flags) — Prism tells you and points to
  claude.com/download. Verified on Windows; macOS/Linux untested.
- Window counts are intentionally absent: there is no honest cross-platform
  way to count another app's windows from a terminal (notably on Wayland).
- Deleting never `rm -rf`s: folders move to a `.trash/` inside their own app
  dir.
- New Cursor profiles get the same per-profile title bar color as the GUI apps.

## Develop

```bash
go run ./tui              # from the repo root (go.work wires it up)
go build -o prism-tui ./tui
go test ./tui/...
gofmt -l tui/
```
Needs Go 1.24+.
