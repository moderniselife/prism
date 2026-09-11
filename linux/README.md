# Prism — Linux (GTK4 + libadwaita)

Native GNOME-styled app, feature-identical to the macOS and Windows versions.
Profiles live in `~/.cursor_profiles`, metadata in `~/.cursor_profiles/.profiles.json`
(same format on all three platforms). Your original Cursor profile (`~/.config/Cursor`)
appears as a protected **Main Cursor** card — launchable and clonable, never deletable.

## Requirements

- GTK 4.10+ and libadwaita 1.2+ with Python bindings
- `pycairo` (python3-cairo) for generating per-profile launcher icons — optional;
  without it, launchers still work but fall back to a generic themed icon

```bash
# Debian/Ubuntu
sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 python3-cairo

# Fedora
sudo dnf install python3-gobject gtk4 libadwaita python3-cairo

# Arch
sudo pacman -S python-gobject gtk4 libadwaita python-cairo
```

## Run

```bash
python3 prism.py
```

## Install (optional)

```bash
mkdir -p ~/.local/bin ~/.local/share/applications
install -m 755 prism.py ~/.local/bin/prism
cp com.mojolayers.Prism.desktop ~/.local/share/applications/
```

## Cursor detection

Checks `cursor` on PATH, `/usr/bin`, `/usr/local/bin`, `/opt/cursor`,
`~/.local/bin`, plus `Cursor*.AppImage` in `~/Applications`, `~/Downloads` and
`~/.local/bin`. A custom path can be set in Preferences.

## Pinning a profile to the dash/dock

The 📌 button on a card (or "Create Dash Launcher…" in its menu) writes a
`.desktop` file to `~/.local/share/applications/cursor-profile-<name>.desktop`
with a generated icon (your profile's color + emoji) in
`~/.local/share/icons/hicolor/256x256/apps/`. It shows up in the app grid —
search for the profile name, then right-click to **Add to Favorites** (GNOME)
or pin to your dock/taskbar (KDE, etc.). It always launches that exact
`--user-data-dir`, so each pinned profile keeps its own icon. Renaming or
recoloring a profile updates its launcher automatically.

**Note:** that custom icon only shows on the *pinned, idle* launcher — once
Cursor actually launches, the dock/taskbar shows Cursor's own icon for the
running window, because Cursor's build crashes if its executable is re-signed
under a different identity (confirmed by testing; deliberate anti-tamper
protection). To tell profiles apart *while running*, see below.

One thing this version does *not* have: the macOS build originally generated a
per-profile wrapper `.app`, which turned out to multiply permission prompts (each
wrapper is a distinct signed app identity, and macOS ties Microphone/Camera/folder
consent to whichever bundle launched Cursor) — that feature was removed there. A
`.desktop` file's `Exec=` line isn't a distinct app identity the same way; it's
just a pointer to the same `cursor` binary (no Flatpak/Snap sandboxing involved
here), so there's no equivalent identity for a permission system to key off, and
nothing extra to worry about here.

## Telling running profiles apart (title bar color)

Since the dock/taskbar icon can't be rebranded once Cursor is open, every
profile automatically gets a distinct title bar color —
`workbench.colorCustomizations` + `"window.titleBarStyle": "custom"`, merged
into that profile's `User/settings.json` (`TitleBarColorizer` class). This
makes Work/Personal/whatever instantly distinguishable in the window itself
and in Alt+Tab, even though the running icon looks like stock Cursor. Any of
your own existing settings in that file are preserved — only the title bar
keys are merged in.
