# Prism

A Mojo Layers project. Native apps for managing isolated [Cursor](https://cursor.sh) profiles.

**Three native versions, one profile format:**

| Platform | Stack | Where |
|----------|-------|-------|
| macOS | SwiftUI | this directory (`Sources/`, `build.sh`) |
| Windows | WPF / .NET 8 | [`windows/`](windows/) |
| Linux | GTK4 + libadwaita (Python) | [`linux/`](linux/) |

All three read and write the same `~/.cursor_profiles` directory and `.profiles.json` metadata (colors, emoji, launch defaults), and all three protect the built-in Cursor profile (macOS: `~/Library/Application Support/Cursor`, Windows: `%APPDATA%\Cursor`, Linux: `~/.config/Cursor`).

The rest of this README covers the macOS app; see `windows/README.md` and `linux/README.md` for those.

Each profile is a separate `--user-data-dir`, so it gets its own settings, extensions, login and chat history. Profiles live in `~/.cursor_profiles`, **existing profiles are picked up automatically**.

## Features

- **Profile grid** — colorful cards with per-profile emoji + accent color, live disk-size and last-launched info
- **Your original Cursor profile is protected** — the built-in profile (`~/Library/Application Support/Cursor`) shows up as a pinned "Main Cursor" card with a BUILT-IN badge. It launches Cursor exactly like opening it normally (no `--user-data-dir`), can be **cloned into a new managed profile** as a starting point, and can never be deleted from the app
- **Create / edit / duplicate / rename** profiles with per-profile launch defaults (memory limit, default project folder)
- **One-click launch** — double-click a card, or use the ⋯ options popover to pick a project folder / memory limit / force a new window for a single launch
- **Drag & drop** — drop any folder onto a card to open it with that profile
- **Running detection** — a live green dot shows which profiles have a Cursor instance open, with a quit button (SIGTERM, graceful)
- **Distinct title bar color per profile** — each profile automatically gets its own title bar color (`workbench.colorCustomizations` + `window.titleBarStyle: "custom"`, written into `User/settings.json`), so Work/Personal/whatever are instantly distinguishable in the window itself, Cmd+Tab and Mission Control. Any of your own existing settings in that file are preserved — only the title bar keys are merged in
- **Menu bar quick launcher** — swap profiles from anywhere without opening the main window
- **Pin, search, sort** (by name / recently used / size)
- **Safe delete** — profiles are moved to the Trash instead of `rm -rf`
- **Auto-detects Cursor** via Launch Services + well-known paths; custom path override in Settings (⌘,)

## Build & run

Requires macOS 14+ and Xcode Command Line Tools (no full Xcode needed).

```bash
./build.sh
open "build/Prism.app"
```

Optionally move it to `/Applications`:

```bash
cp -R "build/Prism.app" /Applications/
```

## Layout

```
Sources/CursorProfiles/
  CursorProfilesApp.swift   # App entry, menu-bar extra, commands
  ContentView.swift         # Main grid, search/sort, empty state
  ProfileCard.swift         # Card UI, launch popover, drag & drop
  ProfileEditorSheet.swift  # Create/edit sheet with live preview
  SettingsView.swift        # Cursor path, defaults, storage
  ProfileStore.swift        # Metadata, CRUD, size + running polling
  CursorLauncher.swift      # Find/launch/quit Cursor processes
  TitleBarColorizer.swift   # Merges a per-profile title bar color into User/settings.json
  Models.swift              # Profile model, palette, helpers
```

Profile metadata (names, colors, defaults) is stored in `~/.cursor_profiles/.profiles.json`; the profile folders themselves are untouched.

## Why there's no "pin to Dock with a custom icon" feature

An earlier version of this app could generate a small wrapper `.app` per profile with its own icon, so you could pin it to the Dock. It was removed. Two reasons:

1. **It didn't actually work while running.** macOS shows the Dock icon of whatever bundle is *actually running* — since the wrapper just launches Cursor's real binary, the running window always showed Cursor's stock icon. The custom icon only ever applied to the idle, not-yet-launched tile.
2. **It multiplied permission prompts.** Each wrapper is a distinct app identity (its own `CFBundleIdentifier`), and macOS's privacy system (TCC) ties consent for Microphone/Camera/folder access/etc. to whichever bundle launched Cursor — not to what it execs into. So every wrapper you created re-triggered Cursor's *entire* permission set as if it were a brand-new, unfamiliar app, one prompt-storm per profile.

If you made any wrapper apps with an older build, delete them from `~/Applications/Prism/` and check System Settings → Privacy & Security for stray entries under their names (not "Cursor") to revoke.

Title bar coloring (`TitleBarColorizer.swift`) replaces it as the way to tell profiles apart while running — it only edits a JSON settings file, no new app identity, no signing, no permission implications.
