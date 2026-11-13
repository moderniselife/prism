# prism-tui — Prism for the terminal

A cross-platform terminal UI for managing isolated [Cursor](https://cursor.sh),
Claude Code, Claude Desktop and Grok Bot profiles. Same profile dirs as the
macOS, Windows and Linux apps — no app required:

- Cursor: `~/.cursor_profiles/.profiles.json`
- Claude Code: `~/.claude_code_profiles/.profiles.json`
- Claude Desktop: `~/.claude_desktop_profiles/.profiles.json`
- Grok Bot: `~/.grokbot_profiles/.profiles.json`

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
| `n` | New profile (`tab` moves fields, `space` switches app, `enter` advances/saves, `esc` cancels). `space` on the last field picks a **fresh account** or an **overflow of** an existing profile of the same app |
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
- Grok Bot profiles launch with `SAND_USER_DATA_DIR=<profile>` (the app's own
  isolation switch: separate login, data in `<profile>/sand-data`, several at
  once) plus a matching `--user-data-dir=` so Prism can spot them running.
- **Fresh vs overflow accounts (every app).** A new profile can start empty, or
  be an *overflow* of an existing profile of the same app: it copies that
  profile's config but none of its identity, so you sign in with your other
  account on first launch. What carries over:
  - **Cursor:** `settings.json`, keybindings, tasks, snippets (extensions are
    already shared). Not the login database or machine id.
  - **Claude Code:** `settings.json`, `CLAUDE.md`, agents, commands, skills,
    output styles, hooks, plugins, plus user-scoped MCP servers and a few
    preferences from `.claude.json`. Not credentials, account ids or history.
  - **Claude Desktop:** `claude_desktop_config.json` and installed extensions
    with their settings. Not cookies or the login.
  - **Grok Bot:** local settings, permission gates and tool approvals.
    Grok Bot's agents live on your account's cloud box, not on disk, so no
    copy can move them — use **Share with team** on an agent in Grok Bot to
    give a second account the same agents.
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
