#!/usr/bin/env python3
"""Cursor Profiles — a native GTK4/libadwaita launcher for isolated Cursor profiles.

Profiles live in ~/.cursor_profiles (same as the macOS/Windows apps); metadata is shared via ~/.cursor_profiles/.profiles.json.
The user's original Cursor profile (~/.config/Cursor) is surfaced as a protected
"Main Cursor" card — launchable and clonable, never deletable.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from glob import glob
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango, PangoCairo  # noqa: E402

try:
    import cairo
except ImportError:
    cairo = None  # icon generation degrades gracefully; everything else still works

APP_ID = "com.deiterate.CursorProfiles"
PROFILES_DIR = Path.home() / ".cursor_profiles"
METADATA_PATH = PROFILES_DIR / ".profiles.json"
SETTINGS_PATH = PROFILES_DIR / ".launcher-settings.json"
SYSTEM_DATA_DIR = Path(GLib.get_user_config_dir()) / "Cursor"
SYSTEM_FOLDER_NAME = "__cursor-default__"

LAUNCHERS_DIR = Path(GLib.get_user_data_dir()) / "applications"
LAUNCHER_ICONS_DIR = Path(GLib.get_user_data_dir()) / "icons" / "hicolor" / "256x256" / "apps"

# Swift's JSONEncoder default: seconds since 2001-01-01 UTC. Keep the file portable.
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)

PALETTE = [
    ("Indigo", "#6366F1"), ("Violet", "#8B5CF6"), ("Fuchsia", "#D946EF"),
    ("Rose", "#F43F5E"), ("Orange", "#F97316"), ("Amber", "#F59E0B"),
    ("Emerald", "#10B981"), ("Teal", "#14B8A6"), ("Sky", "#0EA5E9"),
    ("Blue", "#3B82F6"), ("Slate", "#64748B"), ("Lime", "#84CC16"),
]

EMOJIS = [
    "🖥️", "🚀", "⚡", "🔥", "🧪", "🎨", "🛠️", "🧠", "💼", "🏠",
    "🌙", "☀️", "🐙", "🦄", "🍕", "🎮", "🔒", "🌈", "💎", "🤖",
    "👾", "🧬", "📦", "🪄", "🐉", "🍄", "🌊", "🏴‍☠️", "🎧", "⭐",
]


def apple_seconds(dt):
    return (dt - APPLE_EPOCH).total_seconds() if dt else None


def from_apple_seconds(value):
    return APPLE_EPOCH + timedelta(seconds=value) if value is not None else None


def sanitize_folder_name(raw: str) -> str:
    return "".join(c for c in raw if c.isalnum() or c in "_-")


def format_bytes(size):
    if size is None:
        return "…"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.1f} {unit}".replace(".0 ", " ")
        size /= 1024


def format_relative(dt):
    if dt is None:
        return "never launched"
    span = datetime.now(timezone.utc) - dt
    if span.total_seconds() < 90:
        return "just now"
    if span.total_seconds() < 3600:
        return f"{int(span.total_seconds() // 60)}m ago"
    if span.total_seconds() < 86400:
        return f"{int(span.total_seconds() // 3600)}h ago"
    if span.days < 30:
        return f"{span.days}d ago"
    return dt.astimezone().strftime("%-d %b %Y")


def shade(hex_color: str, factor: float) -> str:
    value = int(hex_color.lstrip("#"), 16)
    r = int(((value >> 16) & 0xFF) * factor)
    g = int(((value >> 8) & 0xFF) * factor)
    b = int((value & 0xFF) * factor)
    return f"#{min(r, 255):02X}{min(g, 255):02X}{min(b, 255):02X}"


# ---------------------------------------------------------------------------
# Model & store
# ---------------------------------------------------------------------------

@dataclass
class Profile:
    folderName: str
    displayName: str
    emoji: str = "🖥️"
    colorHex: str = "#6366F1"
    defaultMemoryMB: int = 16384
    defaultProjectPath: str | None = None
    createdAt: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    lastLaunchedAt: datetime | None = None
    isPinned: bool = False
    isSystem: bool = False

    def to_json(self):
        return {
            "folderName": self.folderName,
            "displayName": self.displayName,
            "emoji": self.emoji,
            "colorHex": self.colorHex,
            "defaultMemoryMB": self.defaultMemoryMB,
            "defaultProjectPath": self.defaultProjectPath,
            "createdAt": apple_seconds(self.createdAt),
            "lastLaunchedAt": apple_seconds(self.lastLaunchedAt),
            "isPinned": self.isPinned,
            "isSystem": self.isSystem,
        }

    @classmethod
    def from_json(cls, data):
        return cls(
            folderName=data["folderName"],
            displayName=data["displayName"],
            emoji=data.get("emoji", "🖥️"),
            colorHex=data.get("colorHex", "#6366F1"),
            defaultMemoryMB=data.get("defaultMemoryMB", 16384),
            defaultProjectPath=data.get("defaultProjectPath"),
            createdAt=from_apple_seconds(data.get("createdAt")) or datetime.now(timezone.utc),
            lastLaunchedAt=from_apple_seconds(data.get("lastLaunchedAt")),
            isPinned=data.get("isPinned", False),
            isSystem=data.get("isSystem", False),
        )


class TitleBarColorizer:
    """A running Cursor window's dash/dock icon can't be rebranded (re-signing
    Cursor's own executable under a different identity crashes it — deliberate
    anti-tamper protection, confirmed against a real install), so the next
    best way to tell profiles apart while they're open is a distinct title
    bar color per profile, visible in the window itself and Alt+Tab."""

    @staticmethod
    def apply(profile: "Profile", profile_dir: Path):
        """Merge this profile's title-bar colors into its User/settings.json,
        preserving every other setting already there. No-op for the built-in
        profile — the user's real settings are never touched."""
        if profile.isSystem:
            return

        user_dir = profile_dir / "User"
        user_dir.mkdir(parents=True, exist_ok=True)
        settings_path = user_dir / "settings.json"

        settings = TitleBarColorizer._read_settings(settings_path)
        colors = settings.get("workbench.colorCustomizations")
        if not isinstance(colors, dict):
            colors = {}
        colors.update(TitleBarColorizer.color_values(profile.colorHex))
        settings["workbench.colorCustomizations"] = colors
        # The default title bar ignores colorCustomizations — required for the colors to render.
        settings["window.titleBarStyle"] = "custom"

        settings_path.write_text(json.dumps(settings, indent=2, ensure_ascii=False))

    @staticmethod
    def color_values(hex_color: str) -> dict:
        foreground = TitleBarColorizer._contrasting_foreground(hex_color)
        return {
            "titleBar.activeBackground": hex_color,
            "titleBar.activeForeground": foreground,
            "titleBar.inactiveBackground": shade(hex_color, 0.55),
            "titleBar.inactiveForeground": foreground + "AA",
        }

    @staticmethod
    def _read_settings(path: Path) -> dict:
        if not path.exists():
            return {}
        try:
            stripped = TitleBarColorizer._strip_json_comments(path.read_text())
            data = json.loads(stripped)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}  # unparsable settings.json — start fresh rather than fail the launch

    @staticmethod
    def _strip_json_comments(text: str) -> str:
        """Strips // and /* */ comments and trailing commas so a hand-edited
        JSONC settings.json (VS Code allows both) round-trips through strict
        JSON parsing. Comments are not preserved on write."""
        result = []
        in_string = False
        escaped = False
        i = 0
        n = len(text)
        while i < n:
            c = text[i]
            if in_string:
                result.append(c)
                if escaped:
                    escaped = False
                elif c == "\\":
                    escaped = True
                elif c == '"':
                    in_string = False
                i += 1
                continue
            if c == '"':
                in_string = True
                result.append(c)
                i += 1
                continue
            if c == "/" and i + 1 < n:
                if text[i + 1] == "/":
                    while i < n and text[i] != "\n":
                        i += 1
                    continue
                if text[i + 1] == "*":
                    i += 2
                    while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                        i += 1
                    i += 2
                    continue
            result.append(c)
            i += 1
        return re.sub(r",\s*([}\]])", r"\1", "".join(result))

    @staticmethod
    def _contrasting_foreground(hex_color: str) -> str:
        r, g, b = (int(hex_color.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
        luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return "#1A1A1A" if luminance > 150 else "#FFFFFF"


class LauncherBuilder:
    """Builds a per-profile .desktop launcher with a generated icon, so a
    profile can be pinned to the dash/dock/taskbar and always opens the
    right --user-data-dir. Filenames are keyed by the stable folder name,
    so renaming a profile updates its launcher in place."""

    ICON_UNAVAILABLE_MESSAGE = (
        "Icon generation needs pycairo (python3-cairo). Install it and try again — "
        "the launcher shortcut itself will still work without a custom icon."
    )

    @staticmethod
    def desktop_path(profile: "Profile") -> Path:
        return LAUNCHERS_DIR / f"cursor-profile-{profile.folderName}.desktop"

    @staticmethod
    def icon_path(profile: "Profile") -> Path:
        return LAUNCHER_ICONS_DIR / f"cursor-profile-{profile.folderName}.png"

    @classmethod
    def exists(cls, profile: "Profile") -> bool:
        return cls.desktop_path(profile).exists()

    @classmethod
    def create_or_update(cls, profile: "Profile", profile_dir: Path, cursor_path: str | None):
        LAUNCHERS_DIR.mkdir(parents=True, exist_ok=True)
        LAUNCHER_ICONS_DIR.mkdir(parents=True, exist_ok=True)

        icon_value = str(cls.icon_path(profile))
        if cairo is not None:
            cls._render_png(profile.emoji, profile.colorHex, cls.icon_path(profile))
        else:
            icon_value = "utilities-terminal"  # themed fallback, always resolvable

        exe = cursor_path or "cursor"
        exec_parts = [_desktop_quote(exe)]
        if not profile.isSystem:
            exec_parts += ["--user-data-dir", _desktop_quote(str(profile_dir))]
        exec_parts.append(f"--max-memory={profile.defaultMemoryMB}")
        if profile.defaultProjectPath:
            exec_parts.append(_desktop_quote(profile.defaultProjectPath))
        exec_line = " ".join(exec_parts)

        content = (
            "[Desktop Entry]\n"
            "Type=Application\n"
            f"Name={profile.displayName}\n"
            f"Comment=Open Cursor with the \"{profile.displayName}\" profile\n"
            f"Exec={exec_line}\n"
            f"Icon={icon_value}\n"
            "Terminal=false\n"
            "Categories=Development;\n"
            "StartupWMClass=Cursor\n"
            "StartupNotify=true\n"
        )
        cls.desktop_path(profile).write_text(content)
        os.chmod(cls.desktop_path(profile), 0o755)
        cls._refresh_desktop_database()

    @classmethod
    def remove(cls, profile: "Profile"):
        for path in (cls.desktop_path(profile), cls.icon_path(profile)):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        cls._refresh_desktop_database()

    @staticmethod
    def _refresh_desktop_database():
        # Best-effort: lets the shell pick up the new launcher immediately
        # rather than waiting for its own periodic rescan.
        try:
            subprocess.run(["update-desktop-database", str(LAUNCHERS_DIR)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            pass

    @staticmethod
    def _render_png(emoji: str, color_hex: str, output_path: Path, size: int = 256):
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
        ctx = cairo.Context(surface)

        inset = size * 0.06
        box = (inset, inset, size - inset * 2, size - inset * 2)
        radius = box[2] * 0.28
        _rounded_rect_path(ctx, *box, radius)

        r, g, b = _hex_to_rgb(color_hex)
        dim = (r * 0.7, g * 0.7, b * 0.7)
        gradient = cairo.LinearGradient(box[0], box[1], box[0] + box[2], box[1] + box[3])
        gradient.add_color_stop_rgb(0, r, g, b)
        gradient.add_color_stop_rgb(1, *dim)
        ctx.set_source(gradient)
        ctx.fill()

        layout = PangoCairo.create_layout(ctx)
        layout.set_text(emoji, -1)
        font = Pango.FontDescription()
        font.set_size(int(size * 0.5 * Pango.SCALE))
        layout.set_font_description(font)
        text_w, text_h = layout.get_pixel_size()
        ctx.move_to((size - text_w) / 2, (size - text_h) / 2)
        ctx.set_source_rgb(1, 1, 1)
        PangoCairo.show_layout(ctx, layout)

        surface.write_to_png(str(output_path))


def _rounded_rect_path(ctx, x, y, w, h, r):
    ctx.new_sub_path()
    ctx.arc(x + w - r, y + r, r, -90 * 3.14159265 / 180, 0)
    ctx.arc(x + w - r, y + h - r, r, 0, 90 * 3.14159265 / 180)
    ctx.arc(x + r, y + h - r, r, 90 * 3.14159265 / 180, 180 * 3.14159265 / 180)
    ctx.arc(x + r, y + r, r, 180 * 3.14159265 / 180, 270 * 3.14159265 / 180)
    ctx.close_path()


def _hex_to_rgb(hex_color: str):
    value = int(hex_color.lstrip("#"), 16)
    return (((value >> 16) & 0xFF) / 255, ((value >> 8) & 0xFF) / 255, (value & 0xFF) / 255)


def _desktop_quote(value: str) -> str:
    """Quote a value for a .desktop Exec= field per the freedesktop spec:
    wrap in double quotes and backslash-escape the characters that stay
    special inside them (\\, ", `, $)."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$")
    return f'"{escaped}"'


class CursorFinder:
    @staticmethod
    def candidates():
        home = Path.home()
        paths = [
            shutil.which("cursor"),
            "/usr/bin/cursor",
            "/usr/local/bin/cursor",
            "/opt/cursor/cursor",
            "/usr/share/cursor/cursor",
            str(home / ".local/bin/cursor"),
        ]
        for pattern in ("Applications/Cursor*.AppImage", "Downloads/Cursor*.AppImage",
                        ".local/bin/Cursor*.AppImage"):
            paths.extend(sorted(glob(str(home / pattern)), reverse=True))
        return [p for p in paths if p]

    @classmethod
    def find(cls, custom_path):
        if custom_path and os.access(custom_path, os.X_OK):
            return custom_path
        for path in cls.candidates():
            if os.access(path, os.X_OK):
                return path
        return None


class Store:
    """Profiles, persistence, launching and background polling."""

    def __init__(self):
        self.profiles: list[Profile] = []
        self.sizes: dict[str, int] = {}
        self.running: dict[str, list[int]] = {}
        self.duplicating: set[str] = set()
        self.settings = self._load_settings()
        self.on_changed = lambda: None      # cards need rebuilding
        self.on_status = lambda: None       # dot/size labels need refreshing
        self.on_error = lambda msg: None
        self.on_info = lambda msg: None
        self.reload()
        GLib.timeout_add_seconds(4, self._poll)

    # -- settings

    def _load_settings(self):
        try:
            return json.loads(SETTINGS_PATH.read_text())
        except (OSError, ValueError):
            return {"customCursorPath": "", "defaultMemoryMB": 16384}

    def save_settings(self):
        PROFILES_DIR.mkdir(parents=True, exist_ok=True)
        SETTINGS_PATH.write_text(json.dumps(self.settings, indent=2))

    @property
    def cursor_path(self):
        return CursorFinder.find(self.settings.get("customCursorPath") or None)

    # -- persistence

    def directory_for(self, profile: Profile) -> Path:
        return SYSTEM_DATA_DIR if profile.isSystem else PROFILES_DIR / profile.folderName

    def reload(self):
        PROFILES_DIR.mkdir(parents=True, exist_ok=True)
        known = []
        try:
            known = [Profile.from_json(x) for x in json.loads(METADATA_PATH.read_text())]
        except (OSError, ValueError, KeyError):
            pass

        on_disk = [p.name for p in PROFILES_DIR.iterdir()
                   if p.is_dir() and not p.name.startswith(".")]

        for name in on_disk:
            if not any(p.folderName == name for p in known):
                display = name.removeprefix("custom_")
                _, hex_color = PALETTE[hash(name) % len(PALETTE)]
                known.append(Profile(folderName=name, displayName=display, colorHex=hex_color))
        # Drop metadata for folders that no longer exist (never the built-in one).
        known = [p for p in known if p.isSystem or p.folderName in on_disk]

        # Surface the user's original Cursor profile — visible, launchable, protected.
        if not any(p.isSystem for p in known) and SYSTEM_DATA_DIR.exists():
            known.insert(0, Profile(
                folderName=SYSTEM_FOLDER_NAME,
                displayName="Main Cursor",
                emoji="⭐",
                colorHex="#3B82F6",
                isPinned=True,
                isSystem=True,
            ))

        self.profiles = known
        self.save_metadata()
        self.on_changed()
        self.refresh_sizes()
        self.refresh_running()

    def save_metadata(self):
        PROFILES_DIR.mkdir(parents=True, exist_ok=True)
        METADATA_PATH.write_text(json.dumps(
            [p.to_json() for p in self.profiles], indent=2, ensure_ascii=False))

    # -- CRUD

    def unique_folder_name(self, base: str) -> str:
        folder, counter = base, 2
        existing = {p.folderName.lower() for p in self.profiles}
        while folder.lower() in existing or folder == SYSTEM_FOLDER_NAME:
            folder = f"{base}-{counter}"
            counter += 1
        return folder

    def create(self, name, emoji, color_hex, memory_mb, project_path):
        base = sanitize_folder_name(name.replace(" ", "_"))
        if not base:
            self.on_error("Profile name must contain at least one letter, number, hyphen or underscore.")
            return None
        profile = Profile(
            folderName=self.unique_folder_name(base),
            displayName=name.strip(),
            emoji=emoji,
            colorHex=color_hex,
            defaultMemoryMB=memory_mb,
            defaultProjectPath=project_path or None,
        )
        try:
            self.directory_for(profile).mkdir(parents=True, exist_ok=True)
        except OSError as e:
            self.on_error(f"Could not create profile folder: {e}")
            return None
        self.profiles.append(profile)
        self.save_metadata()
        self.on_changed()
        self.refresh_sizes()
        TitleBarColorizer.apply(profile, self.directory_for(profile))
        return profile

    def update(self, profile: Profile):
        self.save_metadata()
        self.on_changed()
        # Keep an existing launcher in sync with name/icon/launch changes.
        if not profile.isSystem and LauncherBuilder.exists(profile):
            self.create_or_update_launcher(profile, announce=False)
        TitleBarColorizer.apply(profile, self.directory_for(profile))

    # -- Dash/dock launchers

    def has_launcher(self, profile: Profile) -> bool:
        return LauncherBuilder.exists(profile)

    def create_or_update_launcher(self, profile: Profile, announce=True):
        try:
            LauncherBuilder.create_or_update(profile, self.directory_for(profile), self.cursor_path)
            if announce:
                if cairo is None:
                    self.on_error(LauncherBuilder.ICON_UNAVAILABLE_MESSAGE)
                self.on_info(
                    f"A launcher for \"{profile.displayName}\" was added. "
                    "Find it in your app grid, then right-click to pin it to Favorites/dock.")
        except OSError as e:
            self.on_error(f"Could not create the launcher: {e}")

    def remove_launcher(self, profile: Profile):
        LauncherBuilder.remove(profile)

    def duplicate(self, profile: Profile):
        """Clone a profile. For the built-in profile the original is only read."""
        base = "Main-Cursor-Clone" if profile.isSystem else profile.folderName + "-copy"
        folder = self.unique_folder_name(base)
        source, dest = self.directory_for(profile), PROFILES_DIR / folder
        copy = Profile(
            folderName=folder,
            displayName="Main Cursor Clone" if profile.isSystem else profile.displayName + " Copy",
            emoji=profile.emoji,
            colorHex=profile.colorHex,
            defaultMemoryMB=profile.defaultMemoryMB,
            defaultProjectPath=profile.defaultProjectPath,
        )
        self.duplicating.add(profile.folderName)
        self.on_status()

        def work():
            error = None
            try:
                shutil.copytree(source, dest, symlinks=True,
                                ignore_dangling_symlinks=True, dirs_exist_ok=True)
            except (OSError, shutil.Error) as e:
                error = str(e)
                shutil.rmtree(dest, ignore_errors=True)

            def finish():
                self.duplicating.discard(profile.folderName)
                if error:
                    self.on_error(f"Could not duplicate profile: {error}")
                    self.on_status()
                else:
                    self.profiles.append(copy)
                    self.save_metadata()
                    self.on_changed()
                    self.refresh_sizes()
                return False

            GLib.idle_add(finish)

        threading.Thread(target=work, daemon=True).start()

    def delete(self, profile: Profile):
        """Move the profile folder to the Trash (recoverable)."""
        if profile.isSystem:
            self.on_error("The built-in Cursor profile can't be deleted from here — it's your original Cursor data.")
            return
        if self.running.get(profile.folderName):
            self.on_error(f"'{profile.displayName}' is running. Quit it before deleting.")
            return
        try:
            Gio.File.new_for_path(str(self.directory_for(profile))).trash(None)
        except GLib.Error as e:
            self.on_error(f"Could not move profile to Trash: {e.message}")
            return
        self.remove_launcher(profile)
        self.profiles = [p for p in self.profiles if p.folderName != profile.folderName]
        self.sizes.pop(profile.folderName, None)
        self.save_metadata()
        self.on_changed()

    # -- launch / quit

    def launch(self, profile: Profile, project_path=None, memory_mb=None, new_window=False):
        exe = self.cursor_path
        if not exe:
            self.on_error("Cursor could not be found. Install it from cursor.sh or set a custom path in Preferences.")
            return
        args = [exe]
        if not profile.isSystem:
            profile_dir = self.directory_for(profile)
            profile_dir.mkdir(parents=True, exist_ok=True)
            args += ["--user-data-dir", str(profile_dir)]
            # Idempotent — also covers profiles adopted from disk that never went through create().
            TitleBarColorizer.apply(profile, profile_dir)
        args.append(f"--max-memory={memory_mb or profile.defaultMemoryMB}")
        if new_window:
            args.append("--new-window")
        project = project_path or profile.defaultProjectPath
        if project:
            args.append(project)
        try:
            subprocess.Popen(args, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.on_error(f"Failed to launch Cursor: {e}")
            return
        profile.lastLaunchedAt = datetime.now(timezone.utc)
        self.save_metadata()
        self.on_status()
        GLib.timeout_add_seconds(2, lambda: (self.refresh_running(), False)[1])

    def quit_profile(self, profile: Profile):
        for pid in self.running.get(profile.folderName, []):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        GLib.timeout_add(1500, lambda: (self.refresh_running(), False)[1])

    # -- background polling

    def _poll(self):
        self.refresh_running()
        return True

    def refresh_running(self):
        snapshot = [(p.folderName, str(self.directory_for(p)), p.isSystem) for p in self.profiles]

        def work():
            processes = []
            for entry in os.scandir("/proc"):
                if not entry.name.isdigit():
                    continue
                try:
                    with open(f"/proc/{entry.name}/cmdline", "rb") as f:
                        argv = f.read().decode("utf-8", "replace").split("\0")
                except OSError:
                    continue
                if argv and argv[0]:
                    processes.append((int(entry.name), argv))

            def is_cursor_main(argv):
                exe = os.path.basename(argv[0]).lower()
                looks_like_cursor = exe == "cursor" or exe.endswith(".appimage") and "cursor" in exe
                return looks_like_cursor and not any(a.startswith("--type=") for a in argv)

            result = {}
            for name, directory, is_system in snapshot:
                if is_system:
                    result[name] = [pid for pid, argv in processes
                                    if is_cursor_main(argv) and "--user-data-dir" not in argv]
                else:
                    result[name] = [
                        pid for pid, argv in processes
                        if is_cursor_main(argv) and "--user-data-dir" in argv
                        and argv[argv.index("--user-data-dir") + 1:argv.index("--user-data-dir") + 2] == [directory]
                    ]

            def apply():
                self.running = result
                self.on_status()
                return False

            GLib.idle_add(apply)

        threading.Thread(target=work, daemon=True).start()

    def refresh_sizes(self):
        snapshot = [(p.folderName, self.directory_for(p)) for p in self.profiles]

        def work():
            for name, directory in snapshot:
                total = 0
                for root, _, files in os.walk(directory, onerror=lambda e: None):
                    for f in files:
                        try:
                            total += os.lstat(os.path.join(root, f)).st_size
                        except OSError:
                            pass
                GLib.idle_add(lambda n=name, t=total: (self.sizes.__setitem__(n, t),
                                                       self.on_status(), False)[2])

        threading.Thread(target=work, daemon=True).start()


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

class MainWindow(Adw.ApplicationWindow):
    SORT_MODES = ["Recent", "Name", "Size"]

    def __init__(self, app, store: Store):
        super().__init__(application=app, title="Cursor Profiles",
                         default_width=1000, default_height=660)
        self.store = store
        self.search_text = ""
        self.sort_mode = 0
        self.status_updaters = []
        self._css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), self._css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        store.on_changed = self.rebuild
        store.on_status = self.refresh_status
        store.on_error = self.show_error
        store.on_info = self.show_info

        self.toasts = Adw.ToastOverlay()
        self.set_content(self.toasts)

        root = Adw.ToolbarView()
        self.toasts.set_child(root)

        header = Adw.HeaderBar()
        root.add_top_bar(header)

        new_btn = Gtk.Button(label="New Profile")
        new_btn.add_css_class("suggested-action")
        new_btn.connect("clicked", lambda *_: EditorDialog(self, self.store, None).present())
        header.pack_start(new_btn)

        self.search = Gtk.SearchEntry(placeholder_text="Search profiles")
        self.search.connect("search-changed", self.on_search)
        header.pack_start(self.search)

        prefs_btn = Gtk.Button(icon_name="emblem-system-symbolic", tooltip_text="Preferences")
        prefs_btn.connect("clicked", lambda *_: PreferencesDialog(self, self.store).present())
        header.pack_end(prefs_btn)

        self.sort_btn = Gtk.Button(label="Sort: Recent")
        self.sort_btn.connect("clicked", self.on_sort)
        header.pack_end(self.sort_btn)

        scroller = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        root.set_content(scroller)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        scroller.set_child(outer)

        self.banner = Adw.Banner(
            title="Cursor was not found. Install it from cursor.sh, or set a custom path in Preferences.")
        self.banner.set_button_label("Preferences")
        self.banner.connect("button-clicked", lambda *_: PreferencesDialog(self, self.store).present())
        outer.append(self.banner)

        self.flow = Gtk.FlowBox(
            valign=Gtk.Align.START, max_children_per_line=8, min_children_per_line=1,
            selection_mode=Gtk.SelectionMode.NONE, column_spacing=8, row_spacing=8,
            margin_top=12, margin_bottom=16, margin_start=12, margin_end=12,
            homogeneous=True)
        outer.append(self.flow)

        self.empty = Adw.StatusPage(
            icon_name="folder-templates-symbolic",
            title="No profiles yet",
            description="Each profile is a fully isolated Cursor instance — its own settings, extensions, login and chat history.",
            vexpand=True)
        empty_btn = Gtk.Button(label="Create your first profile", halign=Gtk.Align.CENTER)
        empty_btn.add_css_class("suggested-action")
        empty_btn.add_css_class("pill")
        empty_btn.connect("clicked", lambda *_: EditorDialog(self, self.store, None).present())
        self.empty.set_child(empty_btn)
        outer.append(self.empty)

        self.rebuild()

    # -- helpers

    def show_error(self, message):
        self.toasts.add_toast(Adw.Toast(title=message, timeout=5))

    def show_info(self, message):
        self.toasts.add_toast(Adw.Toast(title=message, timeout=6))

    def on_search(self, entry):
        self.search_text = entry.get_text().strip().lower()
        self.rebuild()

    def on_sort(self, button):
        self.sort_mode = (self.sort_mode + 1) % len(self.SORT_MODES)
        button.set_label(f"Sort: {self.SORT_MODES[self.sort_mode]}")
        self.rebuild()

    def sorted_profiles(self):
        def key(p: Profile):
            primary = (not p.isSystem, not p.isPinned)
            if self.sort_mode == 1:
                return (*primary, p.displayName.lower())
            if self.sort_mode == 2:
                return (*primary, -(self.store.sizes.get(p.folderName) or 0))
            stamp = p.lastLaunchedAt.timestamp() if p.lastLaunchedAt else 0
            return (*primary, -stamp)
        return sorted(self.store.profiles, key=key)

    def visible_profiles(self):
        return [p for p in self.sorted_profiles()
                if not self.search_text
                or self.search_text in p.displayName.lower()
                or self.search_text in p.folderName.lower()]

    # -- CSS for per-profile gradients & accents

    def regenerate_css(self):
        rules = [
            ".profile-card { border-radius: 14px; }",
            ".card-header { border-radius: 13px 13px 0 0; padding: 12px; }",
            ".emoji-tile { background: alpha(white, 0.25); border-radius: 11px; font-size: 22px; }",
            ".on-header { color: white; }",
            ".badge { background: alpha(white, 0.28); color: white; font-size: 8pt; font-weight: 800; "
            "border-radius: 6px; padding: 1px 5px; }",
        ]
        for hex_color in {p.colorHex for p in self.store.profiles} | {h for _, h in PALETTE}:
            tag = hex_color.lstrip("#")
            rules.append(
                f".hdr-{tag} {{ background: linear-gradient(135deg, {hex_color}, {shade(hex_color, 0.68)}); }}")
            rules.append(
                f".btn-{tag} {{ background: {hex_color}; color: white; }}")
            rules.append(
                f".swatch-{tag} {{ background: {hex_color}; border-radius: 999px; min-width: 24px; min-height: 24px; }}")
        self._css.load_from_data("\n".join(rules).encode())

    # -- card construction

    def rebuild(self, *_):
        self.regenerate_css()
        self.status_updaters.clear()
        while (child := self.flow.get_first_child()) is not None:
            self.flow.remove(child)

        profiles = self.visible_profiles()
        for profile in profiles:
            self.flow.append(self.build_card(profile))

        has_any = bool(self.store.profiles)
        self.flow.set_visible(has_any)
        self.empty.set_visible(not has_any)
        self.banner.set_revealed(self.store.cursor_path is None)
        self.refresh_status()

    def build_card(self, profile: Profile):
        tag = profile.colorHex.lstrip("#")
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, width_request=250)
        card.add_css_class("card")
        card.add_css_class("profile-card")

        # Gradient header
        header = Gtk.Box(spacing=12)
        header.add_css_class("card-header")
        header.add_css_class(f"hdr-{tag}")

        emoji = Gtk.Label(label=profile.emoji, width_request=48, height_request=48)
        emoji.add_css_class("emoji-tile")
        header.append(emoji)

        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER, spacing=3)
        name_row = Gtk.Box(spacing=6)
        name = Gtk.Label(label=profile.displayName, xalign=0, max_width_chars=14,
                         ellipsize=Pango.EllipsizeMode.END)
        name.add_css_class("heading")
        name.add_css_class("on-header")
        name_row.append(name)
        if profile.isSystem:
            badge = Gtk.Label(label="BUILT-IN", valign=Gtk.Align.CENTER, tooltip_text=(
                "Your original Cursor profile (~/.config/Cursor). "
                "Launchable and clonable, never deletable from this app."))
            badge.add_css_class("badge")
            name_row.append(badge)
        elif profile.isPinned:
            pin = Gtk.Image.new_from_icon_name("view-pin-symbolic")
            pin.add_css_class("on-header")
            name_row.append(pin)
        title_box.append(name_row)

        status_row = Gtk.Box(spacing=5)
        dot = Gtk.Label(label="●")
        status = Gtk.Label(label="Idle", xalign=0)
        status.add_css_class("caption")
        status.add_css_class("on-header")
        status_row.append(dot)
        status_row.append(status)
        title_box.append(status_row)
        header.append(title_box)
        card.append(header)

        # Details
        details = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8,
                          margin_top=10, margin_bottom=12, margin_start=12, margin_end=12)
        meta = Gtk.Label(xalign=0)
        meta.add_css_class("caption")
        meta.add_css_class("dim-label")
        details.append(meta)

        if profile.defaultProjectPath:
            proj = Gtk.Label(label="📁 " + profile.defaultProjectPath, xalign=0,
                             ellipsize=Pango.EllipsizeMode.MIDDLE)
            proj.add_css_class("caption")
            proj.add_css_class("dim-label")
            details.append(proj)

        buttons = Gtk.Box(spacing=6)
        launch = Gtk.Button(hexpand=True)
        launch.add_css_class(f"btn-{tag}")
        launch.connect("clicked", lambda *_, p=profile: self.store.launch(p))
        buttons.append(launch)

        options = Gtk.Button(icon_name="applications-system-symbolic",
                             tooltip_text="Launch with options…")
        options.connect("clicked", lambda *_, p=profile: LaunchOptionsDialog(self, self.store, p).present())
        buttons.append(options)

        stop = Gtk.Button(icon_name="media-playback-stop-symbolic", tooltip_text="Quit this profile")
        stop.add_css_class("destructive-action")
        stop.connect("clicked", lambda *_, p=profile: self.store.quit_profile(p))
        buttons.append(stop)

        spinner = Gtk.Spinner(tooltip_text="Cloning profile data…")
        buttons.append(spinner)

        pin = Gtk.Button(icon_name="view-pin-symbolic",
                         tooltip_text="Create/update a dash launcher for this profile")
        pin.connect("clicked", lambda *_, p=profile: self.store.create_or_update_launcher(p))
        buttons.append(pin)

        menu = Gtk.MenuButton(icon_name="view-more-symbolic", tooltip_text="More")
        menu.set_popover(self.build_menu(profile))
        buttons.append(menu)
        details.append(buttons)
        card.append(details)

        # Live status updates without rebuilding the grid
        def update():
            running = bool(self.store.running.get(profile.folderName))
            duplicating = profile.folderName in self.store.duplicating
            dot.set_markup(f'<span foreground="{"#4ADE80" if running else "#FFFFFF80"}">●</span>')
            status.set_label("Running" if running else "Idle")
            launch.set_label("New Window" if running else "Launch")
            stop.set_visible(running)
            spinner.set_visible(duplicating)
            spinner.set_spinning(duplicating)
            meta.set_label(
                f"💾 {format_bytes(self.store.sizes.get(profile.folderName))}   "
                f"🕓 {format_relative(profile.lastLaunchedAt)}")
        self.status_updaters.append(update)
        update()

        # Double-click launches; drop a folder to open it with this profile
        click = Gtk.GestureClick(button=1)
        click.connect("released", lambda g, n, x, y, p=profile:
                      self.store.launch(p) if n == 2 else None)
        card.add_controller(click)

        drop = Gtk.DropTarget.new(Gio.File, Gdk.DragAction.LINK | Gdk.DragAction.COPY)
        drop.connect("drop", self.on_drop, profile)
        card.add_controller(drop)

        return card

    def on_drop(self, target, value, x, y, profile):
        path = value.get_path()
        if path and os.path.isdir(path):
            self.store.launch(profile, project_path=path)
            return True
        return False

    def build_menu(self, profile: Profile):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2,
                      margin_top=6, margin_bottom=6, margin_start=6, margin_end=6)
        popover = Gtk.Popover(child=box)

        def item(label, callback, destructive=False, enabled=True):
            btn = Gtk.Button(label=label, has_frame=False, sensitive=enabled)
            btn.get_child().set_xalign(0)
            if destructive:
                btn.add_css_class("destructive-action")
            def run(*_):
                popover.popdown()
                callback()
            btn.connect("clicked", run)
            box.append(btn)

        item("Launch", lambda p=profile: self.store.launch(p))
        item("Launch with Options…", lambda: LaunchOptionsDialog(self, self.store, profile).present())
        item("Unpin" if profile.isPinned else "Pin to Top", lambda: self.toggle_pin(profile))
        item("Edit…", lambda: EditorDialog(self, self.store, profile).present())
        item("Clone into New Profile" if profile.isSystem else "Duplicate",
             lambda: self.store.duplicate(profile),
             enabled=profile.folderName not in self.store.duplicating)
        item("Open in Files", lambda: Gio.AppInfo.launch_default_for_uri(
            Gio.File.new_for_path(str(self.store.directory_for(profile))).get_uri(), None))
        item("Update Dash Launcher" if self.store.has_launcher(profile) else "Create Dash Launcher…",
             lambda: self.store.create_or_update_launcher(profile))
        if self.store.has_launcher(profile):
            item("Remove Dash Launcher", lambda: self.store.remove_launcher(profile))
        if not profile.isSystem:
            item("Move to Trash", lambda: self.confirm_delete(profile), destructive=True)
        return popover

    def toggle_pin(self, profile):
        profile.isPinned = not profile.isPinned
        self.store.update(profile)

    def confirm_delete(self, profile: Profile):
        dialog = Adw.MessageDialog(
            transient_for=self,
            heading=f"Delete “{profile.displayName}”?",
            body=(f"The profile folder ({format_bytes(self.store.sizes.get(profile.folderName))}) "
                  "will be moved to the Trash, including all its settings, extensions and chat history."))
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("delete", "Move to Trash")
        dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.connect("response", lambda d, r: self.store.delete(profile) if r == "delete" else None)
        dialog.present()

    def refresh_status(self, *_):
        for update in self.status_updaters:
            update()


class EditorDialog(Adw.Window):
    """Create or edit a profile, with a live gradient preview."""

    def __init__(self, parent: MainWindow, store: Store, profile: Profile | None):
        super().__init__(transient_for=parent, modal=True, default_width=460,
                         title="Edit Profile" if profile else "New Profile")
        self.parent_window = parent
        self.store = store
        self.profile = profile
        self.emoji = profile.emoji if profile else EMOJIS[0]
        self.color_hex = profile.colorHex if profile else PALETTE[hash(os.urandom(4)) % len(PALETTE)][1]

        root = Adw.ToolbarView()
        self.set_content(root)
        header = Adw.HeaderBar(show_end_title_buttons=False, show_start_title_buttons=False)
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda *_: self.close())
        header.pack_start(cancel)
        save = Gtk.Button(label="Save" if profile else "Create")
        save.add_css_class("suggested-action")
        save.connect("clicked", self.on_save)
        header.pack_end(save)
        root.add_top_bar(header)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.set_content(body)

        # Live preview
        self.preview = Gtk.Box(spacing=12)
        self.preview.add_css_class("card-header")
        self.preview_emoji = Gtk.Label(width_request=48, height_request=48)
        self.preview_emoji.add_css_class("emoji-tile")
        self.preview.append(self.preview_emoji)
        self.preview_name = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self.preview_name.add_css_class("title-2")
        self.preview_name.add_css_class("on-header")
        self.preview.append(self.preview_name)
        body.append(self.preview)

        clamp = Adw.Clamp(margin_top=14, margin_bottom=14, margin_start=16, margin_end=16)
        body.append(clamp)
        form = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        clamp.set_child(form)

        self.name_entry = Gtk.Entry(placeholder_text="e.g. Work, Personal, Experiments",
                                    text=profile.displayName if profile else "")
        self.name_entry.connect("changed", lambda *_: self.update_preview())
        form.append(self._labeled("Name", self.name_entry))

        emoji_flow = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE,
                                 max_children_per_line=10, min_children_per_line=10)
        self.emoji_buttons = {}
        for choice in EMOJIS:
            btn = Gtk.Button(label=choice, has_frame=False)
            btn.connect("clicked", lambda *_, c=choice: self.set_emoji(c))
            self.emoji_buttons[choice] = btn
            emoji_flow.append(btn)
        form.append(self._labeled("Icon", emoji_flow))

        color_box = Gtk.Box(spacing=6)
        self.color_buttons = {}
        for color_name, hex_color in PALETTE:
            btn = Gtk.Button(tooltip_text=color_name, has_frame=False,
                             width_request=26, height_request=26)
            btn.add_css_class(f"swatch-{hex_color.lstrip('#')}")
            btn.add_css_class("circular")
            btn.connect("clicked", lambda *_, h=hex_color: self.set_color(h))
            self.color_buttons[hex_color] = btn
            color_box.append(btn)
        form.append(self._labeled("Color", color_box))

        default_mb = profile.defaultMemoryMB if profile else store.settings.get("defaultMemoryMB", 16384)
        self.memory = Gtk.SpinButton.new_with_range(512, 262144, 1024)
        self.memory.set_value(default_mb)
        form.append(self._labeled("Memory limit (MB)", self.memory))

        project_row = Gtk.Box(spacing=6)
        self.project = Gtk.Entry(hexpand=True, placeholder_text="Optional",
                                 text=(profile.defaultProjectPath or "") if profile else "")
        browse = Gtk.Button(label="Choose…")
        browse.connect("clicked", self.pick_folder)
        project_row.append(self.project)
        project_row.append(browse)
        form.append(self._labeled("Default project folder", project_row))

        if profile:
            note = Gtk.Label(xalign=0, label=(
                "Built-in profile — ~/.config/Cursor" if profile.isSystem
                else f"Folder: {profile.folderName}"))
            note.add_css_class("caption")
            note.add_css_class("dim-label")
            form.append(note)

        self.update_preview()

    @staticmethod
    def _labeled(text, widget):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        label = Gtk.Label(label=text, xalign=0)
        label.add_css_class("heading")
        box.append(label)
        box.append(widget)
        return box

    def set_emoji(self, emoji):
        self.emoji = emoji
        self.update_preview()

    def set_color(self, hex_color):
        self.color_hex = hex_color
        self.update_preview()

    def update_preview(self):
        for css in list(self.preview.get_css_classes()):
            if css.startswith("hdr-"):
                self.preview.remove_css_class(css)
        self.preview.add_css_class(f"hdr-{self.color_hex.lstrip('#')}")
        self.preview_emoji.set_label(self.emoji)
        name = self.name_entry.get_text().strip()
        self.preview_name.set_label(name or "New Profile")
        for choice, btn in self.emoji_buttons.items():
            btn.set_opacity(1.0 if choice == self.emoji else 0.45)
        for hex_color, btn in self.color_buttons.items():
            if hex_color == self.color_hex:
                btn.add_css_class("suggested-action")
            else:
                btn.remove_css_class("suggested-action")

    def pick_folder(self, *_):
        dialog = Gtk.FileDialog()
        def done(d, result):
            try:
                folder = d.select_folder_finish(result)
                if folder:
                    self.project.set_text(folder.get_path() or "")
            except GLib.Error:
                pass
        dialog.select_folder(self, None, done)

    def on_save(self, *_):
        name = self.name_entry.get_text().strip()
        if not name:
            self.parent_window.show_error("Give the profile a name.")
            return
        memory = int(self.memory.get_value())
        project = self.project.get_text().strip() or None
        if self.profile:
            p = self.profile
            p.displayName, p.emoji, p.colorHex = name, self.emoji, self.color_hex
            p.defaultMemoryMB, p.defaultProjectPath = memory, project
            self.store.update(p)
            self.close()
        else:
            if self.store.create(name, self.emoji, self.color_hex, memory, project):
                self.close()


class LaunchOptionsDialog(Adw.Window):
    def __init__(self, parent: MainWindow, store: Store, profile: Profile):
        super().__init__(transient_for=parent, modal=True, default_width=420,
                         title=f"Launch “{profile.displayName}”")
        self.parent_window = parent
        self.store = store
        self.profile = profile

        root = Adw.ToolbarView()
        self.set_content(root)
        header = Adw.HeaderBar(show_end_title_buttons=False, show_start_title_buttons=False)
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda *_: self.close())
        header.pack_start(cancel)
        launch = Gtk.Button(label="Launch")
        launch.add_css_class("suggested-action")
        launch.connect("clicked", self.on_launch)
        header.pack_end(launch)
        root.add_top_bar(header)

        clamp = Adw.Clamp(margin_top=14, margin_bottom=16, margin_start=16, margin_end=16)
        root.set_content(clamp)
        form = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        clamp.set_child(form)

        self.memory = Gtk.SpinButton.new_with_range(512, 262144, 1024)
        self.memory.set_value(profile.defaultMemoryMB)
        form.append(EditorDialog._labeled("Memory limit (MB)", self.memory))

        project_row = Gtk.Box(spacing=6)
        self.project = Gtk.Entry(hexpand=True, placeholder_text="Optional",
                                 text=profile.defaultProjectPath or "")
        browse = Gtk.Button(label="Choose…")
        browse.connect("clicked", self.pick_folder)
        project_row.append(self.project)
        project_row.append(browse)
        form.append(EditorDialog._labeled("Project folder", project_row))

        self.new_window = Gtk.CheckButton(label="Force a new window")
        form.append(self.new_window)

    def pick_folder(self, *_):
        dialog = Gtk.FileDialog()
        def done(d, result):
            try:
                folder = d.select_folder_finish(result)
                if folder:
                    self.project.set_text(folder.get_path() or "")
            except GLib.Error:
                pass
        dialog.select_folder(self, None, done)

    def on_launch(self, *_):
        self.store.launch(
            self.profile,
            project_path=self.project.get_text().strip() or None,
            memory_mb=int(self.memory.get_value()),
            new_window=self.new_window.get_active())
        self.close()


class PreferencesDialog(Adw.PreferencesWindow):
    def __init__(self, parent: MainWindow, store: Store):
        super().__init__(transient_for=parent, modal=True, title="Preferences")
        self.store = store

        page = Adw.PreferencesPage()
        self.add(page)

        cursor_group = Adw.PreferencesGroup(title="Cursor")
        page.add(cursor_group)

        detected = Adw.ActionRow(title="Detected path",
                                 subtitle=store.cursor_path or "Not found")
        cursor_group.add(detected)

        custom = Adw.EntryRow(title="Custom path (empty = auto-detect)")
        custom.set_text(store.settings.get("customCursorPath", ""))
        custom.connect("changed", lambda row: self._set("customCursorPath", row.get_text().strip()))
        cursor_group.add(custom)

        defaults_group = Adw.PreferencesGroup(title="New profile defaults")
        page.add(defaults_group)
        memory_row = Adw.SpinRow.new_with_range(512, 262144, 1024)
        memory_row.set_title("Memory limit (MB)")
        memory_row.set_value(store.settings.get("defaultMemoryMB", 16384))
        memory_row.connect("changed", lambda row: self._set("defaultMemoryMB", int(row.get_value())))
        defaults_group.add(memory_row)

        storage_group = Adw.PreferencesGroup(title="Storage")
        page.add(storage_group)
        dir_row = Adw.ActionRow(title="Profiles folder", subtitle=str(PROFILES_DIR))
        open_btn = Gtk.Button(label="Open", valign=Gtk.Align.CENTER)
        open_btn.connect("clicked", lambda *_: Gio.AppInfo.launch_default_for_uri(
            Gio.File.new_for_path(str(PROFILES_DIR)).get_uri(), None))
        dir_row.add_suffix(open_btn)
        storage_group.add(dir_row)

        rescan_row = Adw.ActionRow(title="Rescan profiles")
        rescan_btn = Gtk.Button(label="Rescan", valign=Gtk.Align.CENTER)
        rescan_btn.connect("clicked", lambda *_: store.reload())
        rescan_row.add_suffix(rescan_btn)
        storage_group.add(rescan_row)

    def _set(self, key, value):
        self.store.settings[key] = value
        self.store.save_settings()


class CursorProfilesApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)
        self.store = None

    def do_activate(self):
        window = self.get_active_window()
        if not window:
            if self.store is None:
                self.store = Store()
            window = MainWindow(self, self.store)
        window.present()


if __name__ == "__main__":
    app = CursorProfilesApp()
    raise SystemExit(app.run(None))
