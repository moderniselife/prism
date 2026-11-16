#!/usr/bin/env python3
"""Prism — a native GTK4/libadwaita launcher for isolated profiles.

Cursor profiles live in ~/.cursor_profiles, Claude Code profiles in
~/.claude_code_profiles, Claude Desktop profiles in
~/.claude_desktop_profiles and Grok Bot profiles in ~/.grokbot_profiles
(shared with the macOS/Windows/TUI apps).
Each app's original data is surfaced as a protected built-in card —
launchable and clonable, never deletable.
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

APP_ID = "com.mojolayers.Prism"
PROFILES_DIR = Path.home() / ".cursor_profiles"
CODE_PROFILES_DIR = Path.home() / ".claude_code_profiles"
DESKTOP_PROFILES_DIR = Path.home() / ".claude_desktop_profiles"
GROK_PROFILES_DIR = Path.home() / ".grokbot_profiles"
METADATA_PATH = PROFILES_DIR / ".profiles.json"
SETTINGS_PATH = PROFILES_DIR / ".launcher-settings.json"
SYSTEM_DATA_DIR = Path(GLib.get_user_config_dir()) / "Cursor"
SYSTEM_FOLDER_NAME = "__cursor-default__"
SYSTEM_CODE_FOLDER_NAME = "__claude-code-default__"
SYSTEM_DESKTOP_FOLDER_NAME = "__claude-desktop-default__"
SYSTEM_GROK_FOLDER_NAME = "__grok-bot-default__"

# App identifiers. Absent in files predating multi-app support (= cursor).
APP_CURSOR = "cursor"
APP_CODE = "claude-code"
APP_DESKTOP = "claude-desktop"
APP_GROK = "grok-bot"

CODE_SYSTEM_DATA_DIR = Path.home() / ".claude"
DESKTOP_SYSTEM_DATA_DIR = Path(GLib.get_user_config_dir()) / "Claude"
GROK_SYSTEM_DATA_DIR = Path(GLib.get_user_config_dir()) / "Grok Bot"

APPS = (APP_CURSOR, APP_CODE, APP_DESKTOP, APP_GROK)


def normalize_app(app):
    return app if app in APPS else APP_CURSOR


def app_label(app):
    return {APP_CODE: "Claude Code", APP_DESKTOP: "Claude Desktop",
            APP_GROK: "Grok Bot"}.get(app, "Cursor")


def system_marker_for(app):
    return {APP_CODE: SYSTEM_CODE_FOLDER_NAME,
            APP_DESKTOP: SYSTEM_DESKTOP_FOLDER_NAME,
            APP_GROK: SYSTEM_GROK_FOLDER_NAME}.get(app, SYSTEM_FOLDER_NAME)


def system_display_name_for(app):
    return {APP_CODE: "Main Claude Code",
            APP_DESKTOP: "Main Claude Desktop",
            APP_GROK: "Main Grok Bot"}.get(app, "Main Cursor")


def profiles_dir_for(app):
    return {APP_CODE: CODE_PROFILES_DIR,
            APP_DESKTOP: DESKTOP_PROFILES_DIR,
            APP_GROK: GROK_PROFILES_DIR}.get(app, PROFILES_DIR)


def system_data_dir_for(app):
    if app == APP_CODE:
        override = os.environ.get("CLAUDE_CONFIG_DIR")
        if override:
            return Path(override)
        return CODE_SYSTEM_DATA_DIR
    if app == APP_DESKTOP:
        return DESKTOP_SYSTEM_DATA_DIR
    if app == APP_GROK:
        return GROK_SYSTEM_DATA_DIR
    return SYSTEM_DATA_DIR


# -- Grok Bot ----------------------------------------------------------------
#
# Grok Bot (Electron) honours SAND_USER_DATA_DIR in release builds: it becomes
# the app's userData *and* moves the agent data root from ~/.grokbot to
# <dir>/sand-data, and the single-instance lock is per directory — so each
# profile is its own instance with its own login. Prism also passes a
# matching --user-data-dir=<dir> (kept by the app across relaunches) purely
# to find the profile in the process list; environment variables are
# invisible there.
#
# A Grok Bot *overflow* profile carries over the local setup only — the data
# root minus anything that identifies an account, a machine or a running
# instance, and settings.json minus its account-scoped keys. Grok Bot's
# agents are not local: they live on the account's cloud box and arrive as a
# server roster, so no copy can move them ("Share with team" in the app can).
# Electron userData is never copied: it holds the encrypted tokens and
# machine id, user secrets, cookies and account-scoped caches. Keep in sync
# with tui/grokbot.go.

GROK_USER_DATA_ENV = "SAND_USER_DATA_DIR"
GROK_DATA_SUBDIR = "sand-data"
GROK_SKIP_TOP = (
    ".grokbot-data-root-v1", "host.lock", "host-token.json", "host-secrets.json",
    "gateway.json", "gateway-descriptor.json", "mcp-auth.json",
    "onepassword-oauth-states.json", "local-tool-spent-sends.json",
    "local-tool-retirements.json", "local-cua-helper.json", "recreate-intent.json",
    "recreate-resume.json", "desktop-status.json", "kept-update.json",
    "dev-box", "computer-use", "logs", "v8-code-cache",
)
GROK_SKIP_TOP_PREFIXES = ("local-exec-",)
# settings.json fields bound to the signed-in account or its cloud box.
GROK_ACCOUNT_SETTINGS_KEYS = (
    "activeAccountScope", "hasSeenOnboardingAccountScope", "hasSeenOnboarding",
    "boxRosterCensus", "egressTunnelCommittedBoxUrls",
)


def grok_carry_over_skips(rel: str) -> bool:
    """Whether a data-root entry (slash-separated, relative) stays behind."""
    parts = rel.split("/")
    leaf = parts[-1].lower()
    if (leaf in ("lockfile", "singletonlock", "singletonsocket", "singletoncookie")
            or leaf.endswith((".lock", ".sock", ".pid"))):
        return True
    top = parts[0]
    if any(top == n or top.startswith(n + ".") for n in GROK_SKIP_TOP):
        return True
    return top.startswith(GROK_SKIP_TOP_PREFIXES)


def grok_system_data_root() -> Path:
    """~/.grokbot, or the pre-rename ~/.cursor/sand on unmigrated installs."""
    canonical = Path.home() / ".grokbot"
    legacy = Path.home() / ".cursor" / "sand"
    if canonical.is_dir():
        return canonical
    return legacy if legacy.is_dir() else canonical


def grok_data_root(profile_dir: Path, is_system: bool) -> Path:
    return grok_system_data_root() if is_system else Path(profile_dir) / GROK_DATA_SUBDIR


def carry_over_grok_data(src_root: Path, dst_root: Path) -> int:
    """Copy agents & config between data roots; returns files copied.
    Symlinks and special files are skipped, never followed."""
    src_root, dst_root = Path(src_root), Path(dst_root)
    if not src_root.is_dir():
        raise OSError(f"nothing to carry over: {src_root} does not exist — "
                      "launch the source profile once first")
    copied = 0

    def walk(src: Path, dst: Path, rel: str):
        nonlocal copied
        dst.mkdir(parents=True, exist_ok=True, mode=0o700)
        for entry in os.scandir(src):
            child_rel = f"{rel}/{entry.name}" if rel else entry.name
            if grok_carry_over_skips(child_rel) or entry.is_symlink():
                continue
            target = dst / entry.name
            if entry.is_dir(follow_symlinks=False):
                walk(Path(entry.path), target, child_rel)
            elif entry.is_file(follow_symlinks=False):
                shutil.copy2(entry.path, target, follow_symlinks=False)
                copied += 1

    walk(src_root, dst_root, "")
    settings = dst_root / "settings.json"
    if settings.is_file():
        try:
            data = json.loads(settings.read_text())
            if not isinstance(data, dict):
                raise ValueError("unexpected settings.json shape")
        except ValueError:
            settings.unlink()  # never carry what can't be vetted
        else:
            for key in GROK_ACCOUNT_SETTINGS_KEYS:
                data.pop(key, None)
            settings.write_text(json.dumps(data, indent=2))
    return copied


# -- Overflow accounts for every app -------------------------------------------
#
# A new profile that carries another same-app profile's config over, never its
# identity. Allowlists wherever an app mixes config and identity, so an unknown
# new token file can never leak. Keep in sync with tui/carryover.go.

CURSOR_CARRY_OVER = ("User/settings.json", "User/keybindings.json",
                     "User/tasks.json", "User/snippets")
DESKTOP_CARRY_OVER = ("claude_desktop_config.json", "Claude Extensions",
                      "Claude Extensions Settings")
CODE_CARRY_OVER = ("settings.json", "CLAUDE.md", "keybindings.json", "agents",
                   "commands", "skills", "output-styles", "hooks", "plugins")
CODE_STATE_KEYS = ("mcpServers", "theme", "editorMode", "autoCompactEnabled",
                   "verbose", "preferredNotifChannel")

def copy_menu_title(app: str) -> str:
    """Grok Bot agents live on the account, so its copy carries settings
    only: don't promise an "overflow" it can't deliver."""
    return ("New Profile with These Settings" if normalize_app(app) == APP_GROK
            else "New Overflow Account from This")


def copy_source_label(source) -> str:
    if normalize_app(source.app) == APP_GROK:
        return f"Settings from {source.displayName} — local settings only, not agents"
    return f"Overflow of {source.displayName} — its config, your other sign-in"


OVERFLOW_EXPLAINERS = {
    APP_CURSOR: "Copies settings, keybindings, tasks and snippets (extensions are already "
                "shared). Its login and machine id stay behind.",
    APP_CODE: "Copies settings, CLAUDE.md, agents, commands, skills, output styles, hooks, "
              "plugins and your user-level MCP servers. Its login, account id and chat "
              "history stay behind.",
    APP_DESKTOP: "Copies the MCP config and installed extensions with their settings. "
                 "Its login and cookies stay behind.",
    APP_GROK: "Copies local settings, permission choices and tool approvals only — not your "
              "agents, which live on your Grok Bot account. To bring an agent across: in the "
              "source profile open it → Create Template → Share a template link → Copy the "
              "share link, then paste that link into a chat in this profile (paste rather "
              "than click, so it opens here).",
}


def _skips_anywhere(name: str) -> bool:
    leaf = name.lower()
    return (leaf in ("lockfile", "singletonlock", "singletonsocket", "singletoncookie")
            or leaf.endswith((".lock", ".sock", ".pid")))


def _copy_tree_no_links(src: Path, dst: Path) -> int:
    """Copy a file or directory, skipping symlinks, special and lock files."""
    if src.is_symlink() or _skips_anywhere(src.name):
        return 0
    if src.is_file():
        dst.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copy2(src, dst, follow_symlinks=False)
        return 1
    if not src.is_dir():
        return 0
    dst.mkdir(parents=True, exist_ok=True, mode=0o700)
    return sum(_copy_tree_no_links(Path(e.path), dst / e.name) for e in os.scandir(src))


def _copy_allowlist(src_dir: Path, dst_dir: Path, entries) -> int:
    if not Path(src_dir).is_dir():
        raise OSError(f"nothing to carry over: {src_dir} does not exist — "
                      "launch the source profile once first")
    return sum(_copy_tree_no_links(Path(src_dir) / rel, Path(dst_dir) / rel)
               for rel in entries if os.path.lexists(Path(src_dir) / rel))


def claude_code_state_file(config_dir: Path, is_system: bool) -> Path:
    """.claude.json lives in $HOME for the default config dir."""
    if is_system and not os.environ.get("CLAUDE_CONFIG_DIR"):
        return Path.home() / ".claude.json"
    return Path(config_dir) / ".claude.json"


def carry_over(app: str, src_dir: Path, src_is_system: bool, dst_dir: Path) -> int:
    """Copy a profile's config (never its identity) into a new profile dir."""
    app = normalize_app(app)
    src_dir, dst_dir = Path(src_dir), Path(dst_dir)
    if app == APP_GROK:
        return carry_over_grok_data(grok_data_root(src_dir, src_is_system),
                                    grok_data_root(dst_dir, False))
    if app == APP_DESKTOP:
        return _copy_allowlist(src_dir, dst_dir, DESKTOP_CARRY_OVER)
    if app == APP_CURSOR:
        return _copy_allowlist(src_dir, dst_dir, CURSOR_CARRY_OVER)
    copied = _copy_allowlist(src_dir, dst_dir, CODE_CARRY_OVER)
    # Plugin bookkeeping records absolute install paths: repoint them.
    plugins = dst_dir / "plugins"
    if plugins.is_dir():
        pairs = [(str(src_dir), str(dst_dir)),
                 (json.dumps(str(src_dir))[1:-1], json.dumps(str(dst_dir))[1:-1])]
        for path in plugins.rglob("*.json"):
            if path.is_symlink() or not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            new = text
            for old, repl in pairs:
                new = new.replace(old, repl)
            if new != text:
                path.write_text(new, encoding="utf-8")
    state = claude_code_state_file(src_dir, src_is_system)
    if state.is_file():
        data = json.loads(state.read_text())
        kept = {k: data[k] for k in CODE_STATE_KEYS if isinstance(data, dict) and k in data}
        if kept:
            out = dst_dir / ".claude.json"
            out.write_text(json.dumps(kept, indent=2))
            os.chmod(out, 0o600)
            copied += 1
    return copied

# -- Second brain (Brainium) ---------------------------------------------------
#
# Prism wires Brainium (github.com/moderniselife/brainium) into every profile
# so agents share one git-backed memory across apps and accounts. Prism stays
# thin: it finds node and a Brainium checkout and runs its CLI. Brainium's own
# config (personal brain, capture, summarizer) is the single source of truth,
# shared with its hooks and MCP server. Keep in sync with tui/brainium.go.

BRAINIUM_PROVIDERS = (
    ("agent", "Your AI, via MCP (no extra cost)"),
    ("none", "No AI (mechanical summary)"),
    ("anthropic", "Anthropic API"),
    ("openai", "OpenAI API"),
    ("bonsai", "Bonsai (self-hosted)"),
    ("openai-compatible", "Other OpenAI-compatible API"),
)

BRAINIUM_NOT_FOUND = "Brainium isn't set up yet. Open Preferences → Second brain and click Install."
BRAINIUM_REPO = "https://github.com/moderniselife/brainium.git"
BRAINIUM_TARBALL = "https://codeload.github.com/moderniselife/brainium/tar.gz/refs/heads/main"
NODE_DOWNLOAD_URL = "https://nodejs.org/en/download"


def _version_key(name: str):
    return [int(p) if p.isdigit() else 0 for p in name.lstrip("v").split(".")]


def find_node(custom: str = "") -> str | None:
    """node: custom -> PATH -> nvm (newest) -> system/Volta. Launchers from
    the app grid don't always get the shell PATH, so the fallbacks matter."""
    if custom and os.path.isfile(custom):
        return custom
    found = shutil.which("node")
    if found:
        return found
    home = Path.home()
    nvm = home / ".nvm" / "versions" / "node"
    candidates = []
    if nvm.is_dir():
        candidates += [str(d / "bin" / "node")
                       for d in sorted(nvm.iterdir(), key=lambda d: _version_key(d.name), reverse=True)]
    candidates += ["/usr/local/bin/node", "/usr/bin/node", str(home / ".volta" / "bin" / "node")]
    return next((c for c in candidates if os.path.isfile(c)), None)


def find_brainium_cli(custom: str = "") -> str | None:
    """bin/brainium.mjs: custom (checkout or script) -> $BRAINIUM_HOME -> common clones."""
    if custom.endswith(".mjs") and os.path.isfile(custom):
        return custom
    home = Path.home()
    dirs = ([custom] if custom else []) + ([os.environ["BRAINIUM_HOME"]] if os.environ.get("BRAINIUM_HOME") else [])
    dirs += [str(home / d) for d in ("brainium", "Projects/brainium", "src/brainium", "code/brainium")]
    return next((c for c in (os.path.join(d, "bin", "brainium.mjs") for d in dirs) if os.path.isfile(c)), None)


def brain_wire_args(app: str, profile_dir: str, is_system: bool, capture: bool, enable: bool = True):
    """CLI args to (un)wire one profile, or None when the app has nothing local
    to wire (Grok Bot agents run in the cloud: they get a snippet)."""
    verb = "wire" if enable else "unwire"
    app = normalize_app(app)
    if app == APP_CODE:
        args = [verb, "--app", "claude-code", "--profile", profile_dir, "--json"]
        if is_system:
            args.append("--system")
        if enable and capture:
            args.append("--capture")
        return args
    if app == APP_DESKTOP:
        return [verb, "--app", "claude-desktop", "--profile", profile_dir, "--json"]
    if app == APP_CURSOR:
        return [verb, "--app", "cursor", "--json"]
    return None


class Brainium:
    def __init__(self, node: str, cli: str):
        self.node, self.cli = node, cli

    @classmethod
    def resolve(cls, cli_path: str = "", node_path: str = ""):
        node, cli = find_node(node_path), find_brainium_cli(cli_path)
        return cls(node, cli) if node and cli else None

    def run(self, *args) -> str:
        proc = subprocess.run([self.node, self.cli, *args], capture_output=True, text=True, timeout=120)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or f"brainium exited with {proc.returncode}")
        return proc.stdout

    def status(self) -> dict:
        return json.loads(self.run("status", "--json"))

    def wire_all(self, targets, enable: bool = True) -> str:
        """targets: [(app, dir, is_system)]. Cursor's shared config is wired once."""
        st = self.status()
        if enable and not st.get("personalExists"):
            raise RuntimeError("Create your personal brain first.")
        done, cursor_done, problems = 0, False, []
        for app, directory, is_system in targets:
            args = brain_wire_args(app, str(directory), is_system, bool(st.get("capture")), enable)
            if args is None:
                continue
            if normalize_app(app) == APP_CURSOR:
                if cursor_done:
                    done += 1
                    continue
                cursor_done = True
            try:
                self.run(*args)
                done += 1
            except (OSError, RuntimeError, subprocess.SubprocessError) as e:
                problems.append(f"{Path(directory).name}: {e}")
        summary = f"{'Wired' if enable else 'Unwired'} {done} profile{'' if done == 1 else 's'}."
        return summary + (" Problems: " + "; ".join(problems) if problems else "")


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

# -- Endpoint (prism-endpoint helper) -------------------------------------------
# A local OpenAI/Anthropic-compatible API that sends each request with the API
# keys of an identity (Work, Personal…). The Go helper does the work; Prism
# finds or installs it, starts and stops it, edits its settings and talks to
# its admin API. Keys go to the system keyring through the helper, never into
# the settings file.

PRISM_VERSION = "1.5.0"  # stamped by the release workflow
GITHUB_REPO = "moderniselife/prism"
ENDPOINT_DEFAULT_PORT = 4848
ENDPOINT_PROVIDERS = [("anthropic", "Anthropic"), ("openai", "OpenAI"), ("xai", "xAI"),
                      ("compatible", "OpenAI-compatible")]
ENDPOINT_RULE_KINDS = [("keyword", "Message mentions"), ("regex", "Message matches regex"),
                       ("client", "Request comes from app"), ("schedule", "Time of day")]
ENDPOINT_BUDGET_ACTIONS = [("warn", "Warn me"), ("fallback", "Use the fallback"),
                           ("block", "Block requests")]
ENDPOINT_COLORS = ["#3B82F6", "#22C55E", "#F59E0B", "#EF4444", "#EC4899", "#8B5CF6", "#14B8A6", "#64748B"]
_TOKEN_ALPHABET = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def endpoint_provider_label(provider: str) -> str:
    return dict(ENDPOINT_PROVIDERS).get(provider, "OpenAI-compatible")


def endpoint_new_token() -> str:
    import secrets
    return "prism-" + "".join(secrets.choice(_TOKEN_ALPHABET) for _ in range(32))


def endpoint_new_id() -> str:
    import uuid
    return str(uuid.uuid4()).upper()


def endpoint_slug(name: str) -> str:
    out, dash = [], False
    for ch in (name or "").lower():
        if ch.isalnum():
            out.append(ch)
            dash = False
        elif not dash and out:
            out.append("-")
            dash = True
    return "".join(out).strip("-")


def endpoint_dir() -> Path:
    if os.environ.get("PRISM_ENDPOINT_DIR"):
        return Path(os.environ["PRISM_ENDPOINT_DIR"])
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "prism"


def endpoint_config_path() -> Path:
    if os.environ.get("PRISM_ENDPOINT_CONFIG"):
        return Path(os.environ["PRISM_ENDPOINT_CONFIG"])
    return endpoint_dir() / "endpoint.json"


def _arch() -> str:
    import platform
    m = platform.machine().lower()
    return "arm64" if m in ("aarch64", "arm64") else "amd64"


def github_latest_release(timeout=15):
    import urllib.request
    req = urllib.request.Request(f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest",
                                 headers={"User-Agent": f"Prism-Linux/{PRISM_VERSION}",
                                          "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def version_tuple(text: str):
    parts = re.findall(r"\d+", (text or "").lstrip("v"))[:3]
    return tuple(int(p) for p in parts) + (0,) * (3 - len(parts))


class Endpoint:
    HELPER = "prism-endpoint"

    def __init__(self):
        self.config = {}
        self.reload()

    # -- settings

    @staticmethod
    def defaults():
        return {"enabled": False, "port": ENDPOINT_DEFAULT_PORT, "allowLAN": False, "requireToken": True,
                "token": endpoint_new_token(), "identities": [], "tagsEnabled": True, "rules": [],
                "modelList": "both"}

    def reload(self):
        cfg = self.defaults()
        try:
            data = json.loads(endpoint_config_path().read_text())
            if isinstance(data, dict):
                cfg.update({k: v for k, v in data.items() if v is not None})
        except (OSError, ValueError):
            pass
        for ident in cfg["identities"]:
            ident.setdefault("id", endpoint_new_id())
            ident.setdefault("credentials", [])
            ident.setdefault("token", endpoint_new_token())
            ident.setdefault("colorHex", ENDPOINT_COLORS[0])
            ident.setdefault("defaultModel", "")
        self.config = cfg

    def save(self):
        path = endpoint_config_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".json.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(self.config, f, indent=2)
        os.replace(tmp, path)
        try:
            self.admin("POST", "/prism/reload", {}, timeout=2)
        except OSError:
            pass  # not running: it reads the file when it starts

    @property
    def identities(self) -> list:
        return self.config["identities"]

    def identity(self, ident_id):
        return next((i for i in self.identities if i.get("id") == ident_id), None)

    @property
    def active(self):
        return self.identity(self.config.get("activeIdentityID")) or (self.identities[0] if self.identities else None)

    @property
    def port(self) -> int:
        return int(self.config.get("port") or ENDPOINT_DEFAULT_PORT)

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    # -- helper

    @classmethod
    def find_helper(cls):
        here = Path(__file__).resolve().parent
        for candidate in (here / cls.HELPER, Path.home() / ".local" / "bin" / cls.HELPER):
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate)
        found = shutil.which(cls.HELPER)
        if found:
            return found
        # prism-tui runs the same endpoint as "prism-tui endpoint".
        return None

    @classmethod
    def install_helper(cls) -> str:
        """Download the helper for this machine from the latest release (blocking)."""
        import urllib.request
        asset = f"prism-endpoint-linux-{_arch()}"
        release = github_latest_release()
        url = next((a.get("browser_download_url") for a in release.get("assets", [])
                    if a.get("name") == asset), None)
        if not url:
            raise RuntimeError("The latest Prism release has no endpoint helper for Linux yet.")
        dest = Path.home() / ".local" / "bin" / cls.HELPER
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".download")
        req = urllib.request.Request(url, headers={"User-Agent": f"Prism-Linux/{PRISM_VERSION}"})
        with urllib.request.urlopen(req, timeout=300) as resp, open(tmp, "wb") as out:
            shutil.copyfileobj(resp, out)
        os.chmod(tmp, 0o755)
        os.replace(tmp, dest)
        return str(dest)

    # -- admin API (main token)

    def admin(self, method, route, body=None, timeout=20):
        """Returns the decoded JSON reply. Raises OSError when not running."""
        import urllib.error
        import urllib.request
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base_url + route, data=data, method=method, headers={
            "Authorization": f"Bearer {self.config.get('token', '')}",
            "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            try:
                return json.loads(e.read().decode() or "{}")
            except ValueError:
                return {"error": f"HTTP {e.code}"}

    @staticmethod
    def error_text(reply) -> str | None:
        err = (reply or {}).get("error")
        if isinstance(err, dict):
            return err.get("message")
        return err

    def status(self):
        try:
            reply = self.admin("GET", "/prism/status", timeout=3)
            return reply if "identities" in reply else None
        except (OSError, ValueError):
            return None

    def start(self) -> str | None:
        """Start the helper in the background (blocking up to 5s)."""
        import time
        helper = self.find_helper()
        if not helper:
            return "The endpoint helper isn't installed."
        if not self.config.get("enabled"):
            self.config["enabled"] = True
            self.save()
        try:
            subprocess.Popen([helper, "serve"], start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            return str(e)
        for _ in range(20):
            time.sleep(0.25)
            if self.status() is not None:
                return None
        return f"The endpoint didn't start. Is port {self.port} in use?"

    def stop(self):
        self.config["enabled"] = False
        self.save()
        try:
            self.admin("POST", "/prism/stop", {}, timeout=3)
        except OSError:
            pass

    def set_active(self, ident_id) -> str | None:
        self.config["activeIdentityID"] = ident_id
        self.save()
        return None

    def set_key(self, cred_id, key) -> str | None:
        try:
            reply = self.admin("POST", "/prism/key", {"credentialID": cred_id, "key": key})
            return None if reply.get("ok") else (self.error_text(reply) or "Couldn't save the key.")
        except OSError:
            pass
        helper = self.find_helper()
        if not helper:
            return "Install the endpoint helper first."
        try:
            done = subprocess.run([helper, "key", cred_id], input=key, text=True,
                                  capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as e:
            return str(e)
        return None if done.returncode == 0 else (done.stderr.strip() or "Couldn't save the key.")

    def check(self, cred_id):
        """(error, models) for a saved credential."""
        try:
            reply = self.admin("POST", "/prism/check", {"credentialID": cred_id}, timeout=20)
        except OSError:
            return "The endpoint isn't running.", []
        if reply.get("ok"):
            return None, reply.get("models") or []
        return self.error_text(reply) or "Check failed.", []

    def claude_code_env(self, ident_id) -> dict:
        """Environment for a Claude Code profile that goes through the endpoint
        (None = the profile's own sign-in, "*" = whichever identity is active)."""
        if not ident_id:
            return {}
        token = self.config.get("token") if ident_id == "*" else (self.identity(ident_id) or {}).get("token")
        if not token:
            return {}
        return {"ANTHROPIC_BASE_URL": self.base_url, "ANTHROPIC_AUTH_TOKEN": token}

    # -- setup snippets

    def snippet(self, kind: str, token: str) -> str:
        base = self.base_url
        if kind == "code":
            return f'export ANTHROPIC_BASE_URL="{base}"\nexport ANTHROPIC_AUTH_TOKEN="{token}"'
        if kind == "codex":
            model = (self.active or {}).get("defaultModel") or "gpt-5-codex"
            return (f'# ~/.codex/config.toml\nmodel = "{model}"\nmodel_provider = "prism"\n\n'
                    f'[model_providers.prism]\nname = "Prism"\nbase_url = "{base}/v1"\n'
                    f'env_key = "PRISM_API_KEY"\nwire_api = "responses"\n\n'
                    f'# and in your shell profile:\nexport PRISM_API_KEY="{token}"')
        if kind == "desktop":
            return (f"Developer → Configure Third-Party Inference…\nInference provider   Gateway\n"
                    f"Gateway base URL     {base}\nGateway API key      {token}\nGateway auth scheme  Bearer")
        return (f"Base URL   {base}/v1\nAPI key    {token}\nModel      prism  (follows the active identity)\n"
                f"           or work/…, personal/… to pin one\n\n"
                f"Open WebUI in Docker: http://host.docker.internal:{self.port}/v1")


def run_in_background(work, done=None):
    """Run work() on a thread, then done(result, error) on the GTK main loop."""
    def run():
        try:
            result, error = work(), None
        except Exception as e:  # noqa: BLE001 — shown to the user
            result, error = None, e
        if done:
            GLib.idle_add(lambda: (done(result, error), False)[1])
    threading.Thread(target=run, daemon=True).start()


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
    # NOTE: older .profiles.json files may contain an "emoji" key. It has no
    # corresponding field; .get() lookups below simply ignore it, so old
    # files still load and new files omit it. Likewise a missing "app" means
    # a Cursor profile (predates multi-app support).
    app: str = APP_CURSOR
    colorHex: str = "#6366F1"
    defaultMemoryMB: int = 16384
    defaultProjectPath: str | None = None
    createdAt: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    lastLaunchedAt: datetime | None = None
    isPinned: bool = False
    isSystem: bool = False
    # Claude Code only: go through the Prism endpoint. None = the profile's own
    # sign-in, "*" = the active identity, otherwise an endpoint identity id.
    endpointIdentity: str | None = None

    @property
    def initial(self) -> str:
        """Tile glyph: first letter of the display name, uppercased."""
        name = (self.displayName or "").strip()
        return name[0].upper() if name else "?"

    def to_json(self):
        return {
            "folderName": self.folderName,
            "displayName": self.displayName,
            "app": normalize_app(self.app),
            "colorHex": self.colorHex,
            "defaultMemoryMB": self.defaultMemoryMB,
            "defaultProjectPath": self.defaultProjectPath,
            "createdAt": apple_seconds(self.createdAt),
            "lastLaunchedAt": apple_seconds(self.lastLaunchedAt),
            "isPinned": self.isPinned,
            "isSystem": self.isSystem,
            **({"endpointIdentity": self.endpointIdentity} if self.endpointIdentity else {}),
        }

    @classmethod
    def from_json(cls, data):
        return cls(
            folderName=data["folderName"],
            displayName=data["displayName"],
            app=normalize_app(data.get("app", APP_CURSOR)),
            colorHex=data.get("colorHex", "#6366F1"),
            defaultMemoryMB=data.get("defaultMemoryMB", 16384),
            defaultProjectPath=data.get("defaultProjectPath"),
            createdAt=from_apple_seconds(data.get("createdAt")) or datetime.now(timezone.utc),
            lastLaunchedAt=from_apple_seconds(data.get("lastLaunchedAt")),
            isPinned=data.get("isPinned", False),
            isSystem=data.get("isSystem", False),
            endpointIdentity=data.get("endpointIdentity"),
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
        if profile.isSystem or normalize_app(profile.app) != APP_CURSOR:
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
    def slug(profile: "Profile") -> str:
        # Folder names are globally unique across apps, so one slug works
        # everywhere; the app prefix keeps launchers distinguishable.
        prefix = {APP_CODE: "claude-code", APP_DESKTOP: "claude-desktop",
                  APP_GROK: "grok-bot"}.get(normalize_app(profile.app), "cursor")
        return f"{prefix}-profile-{profile.folderName}"

    @staticmethod
    def desktop_path(profile: "Profile") -> Path:
        return LAUNCHERS_DIR / f"{LauncherBuilder.slug(profile)}.desktop"

    @staticmethod
    def icon_path(profile: "Profile") -> Path:
        return LAUNCHER_ICONS_DIR / f"{LauncherBuilder.slug(profile)}.png"

    @classmethod
    def exists(cls, profile: "Profile") -> bool:
        return cls.desktop_path(profile).exists()

    @classmethod
    def create_or_update(cls, profile: "Profile", profile_dir: Path,
                         cursor_path: str | None, code_path: str | None = None,
                         desktop_path: str | None = None, grok_path: str | None = None):
        LAUNCHERS_DIR.mkdir(parents=True, exist_ok=True)
        LAUNCHER_ICONS_DIR.mkdir(parents=True, exist_ok=True)

        icon_value = str(cls.icon_path(profile))
        if cairo is not None:
            cls._render_png(profile.initial, profile.colorHex, cls.icon_path(profile))
        else:
            icon_value = "utilities-terminal"  # themed fallback, always resolvable

        app = normalize_app(profile.app)
        if app == APP_CODE:
            # .desktop files cannot set env vars: run through sh so the
            # profile travels in CLAUDE_CONFIG_DIR. Terminal=true keeps the
            # interactive CLI (and its login flow) visible.
            exe = code_path or "claude"
            work = profile.defaultProjectPath or str(Path.home())
            inner = (f"CLAUDE_CONFIG_DIR={_desktop_quote(str(profile_dir))} "
                     f"exec {_desktop_quote(exe)}")
            exec_line = f"sh -c {_desktop_quote(inner)}"
            content = (
                "[Desktop Entry]\n"
                "Type=Application\n"
                f"Name={profile.displayName} (Claude Code)\n"
                f"Comment=Open Claude Code with the \"{profile.displayName}\" profile\n"
                f"Exec={exec_line}\n"
                f"Path={work}\n"
                f"Icon={icon_value}\n"
                "Terminal=true\n"
                "Categories=Development;\n"
                "StartupNotify=true\n"
            )
        elif app == APP_DESKTOP:
            exe = desktop_path or "claude-desktop"
            exec_parts = [_desktop_quote(exe)]
            if not profile.isSystem:
                exec_parts.append(_desktop_quote(f"--user-data-dir={profile_dir}"))
            exec_line = " ".join(exec_parts)
            content = (
                "[Desktop Entry]\n"
                "Type=Application\n"
                f"Name={profile.displayName} (Claude Desktop)\n"
                f"Comment=Open Claude Desktop with the \"{profile.displayName}\" profile\n"
                f"Exec={exec_line}\n"
                f"Icon={icon_value}\n"
                "Terminal=false\n"
                "Categories=Development;\n"
                "StartupWMClass=Claude\n"
                "StartupNotify=true\n"
            )
        elif app == APP_GROK:
            # .desktop files can't set env vars directly: `env` does it.
            exe = grok_path or "grok-bot"
            exec_parts = [_desktop_quote(exe)]
            if not profile.isSystem:
                exec_parts = ["env", _desktop_quote(f"{GROK_USER_DATA_ENV}={profile_dir}"),
                              _desktop_quote(exe),
                              _desktop_quote(f"--user-data-dir={profile_dir}")]
            exec_line = " ".join(exec_parts)
            content = (
                "[Desktop Entry]\n"
                "Type=Application\n"
                f"Name={profile.displayName} (Grok Bot)\n"
                f"Comment=Open Grok Bot with the \"{profile.displayName}\" profile\n"
                f"Exec={exec_line}\n"
                f"Icon={icon_value}\n"
                "Terminal=false\n"
                "Categories=Development;\n"
                "StartupNotify=true\n"
            )
        else:
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
    def _render_png(glyph: str, color_hex: str, output_path: Path, size: int = 256):
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
        layout.set_text(glyph, -1)
        font = Pango.FontDescription()
        font.set_weight(Pango.Weight.BOLD)
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

    @staticmethod
    def code_candidates():
        home = Path.home()
        return [
            shutil.which("claude"),
            "/usr/bin/claude",
            "/usr/local/bin/claude",
            str(home / ".local/bin/claude"),
        ]

    @classmethod
    def find_code(cls, custom_path):
        if custom_path and os.access(custom_path, os.X_OK):
            return custom_path
        for path in cls.code_candidates():
            if path and os.access(path, os.X_OK):
                return path
        return None

    @staticmethod
    def desktop_candidates():
        home = Path.home()
        return [
            shutil.which("claude-desktop"),
            "/usr/bin/claude-desktop",
            "/usr/local/bin/claude-desktop",
            "/opt/Claude/claude-desktop",
            str(home / ".local/bin/claude-desktop"),
        ]

    @classmethod
    def find_desktop(cls, custom_path):
        if custom_path and os.access(custom_path, os.X_OK):
            return custom_path
        for path in cls.desktop_candidates():
            if path and os.access(path, os.X_OK):
                return path
        return None

    @staticmethod
    def grok_candidates():
        home = Path.home()
        return [
            shutil.which("grok-bot"),
            "/usr/bin/grok-bot",
            "/usr/local/bin/grok-bot",
            "/opt/Grok Bot/grok-bot",
            str(home / ".local/bin/grok-bot"),
        ]

    @classmethod
    def find_grok(cls, custom_path):
        if custom_path and os.access(custom_path, os.X_OK):
            return custom_path
        for path in cls.grok_candidates():
            if path and os.access(path, os.X_OK):
                return path
        return None


def rss_of_pid(pid: int) -> int:
    """Live resident bytes for one PID via /proc. 0 if it just exited."""
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    return 0


def total_physical_memory() -> int:
    """Real total RAM from /proc/meminfo. 0 if unreadable (UI shows a dash)."""
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    return 0


class Store:
    """Profiles, persistence, launching and background polling."""

    def __init__(self):
        self.profiles: list[Profile] = []
        self.sizes: dict[str, int] = {}
        self.running: dict[str, list[int]] = {}
        self.live_bytes: dict[str, int] = {}
        self.system_cpu = None  # percent; None until the second sample
        self.total_memory = total_physical_memory()
        self._prev_cpu = None
        self._cpu_lock = threading.Lock()
        self.duplicating: set[str] = set()
        self.brain_status: dict | None = None  # last `brainium status --json`
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
            return {"customCursorPath": "", "customCodePath": "",
                    "customDesktopPath": "", "customGrokPath": "",
                    "defaultMemoryMB": 16384}

    def save_settings(self):
        PROFILES_DIR.mkdir(parents=True, exist_ok=True)
        SETTINGS_PATH.write_text(json.dumps(self.settings, indent=2))

    @property
    def cursor_path(self):
        return CursorFinder.find(self.settings.get("customCursorPath") or None)

    @property
    def code_path(self):
        return CursorFinder.find_code(self.settings.get("customCodePath") or None)

    @property
    def desktop_path(self):
        return CursorFinder.find_desktop(self.settings.get("customDesktopPath") or None)

    @property
    def grok_path(self):
        return CursorFinder.find_grok(self.settings.get("customGrokPath") or None)

    # -- persistence

    def directory_for(self, profile: Profile) -> Path:
        app = normalize_app(profile.app)
        if profile.isSystem:
            return system_data_dir_for(app)
        return profiles_dir_for(app) / profile.folderName

    def metadata_path_for(self, app: str) -> Path:
        return profiles_dir_for(app) / ".profiles.json"

    def reload(self):
        self.profiles = []
        for app in APPS:
            self.profiles.extend(self.reload_app(app))
        self.save_metadata()
        self.on_changed()
        self.refresh_sizes()
        self.refresh_running()

    def reload_app(self, app: str) -> list:
        app_dir = profiles_dir_for(app)
        app_dir.mkdir(parents=True, exist_ok=True)
        known = []
        try:
            known = [Profile.from_json(x)
                     for x in json.loads(self.metadata_path_for(app).read_text())]
        except (OSError, ValueError, KeyError):
            pass

        # Foreign built-ins (from a copied metadata file) belong to their own
        # app; hand-created folders are adopted into this app.
        known = [q for q in known
                 if not (q.isSystem and q.folderName != system_marker_for(app))]
        for q in known:
            q.app = app

        on_disk = [x.name for x in app_dir.iterdir()
                   if x.is_dir() and not x.name.startswith(".")]

        for name in on_disk:
            if not any(q.folderName == name for q in known):
                display = name.removeprefix("custom_")
                _, hex_color = PALETTE[hash(name) % len(PALETTE)]
                known.append(Profile(folderName=name, displayName=display,
                                     app=app, colorHex=hex_color))
        # Drop metadata for folders that no longer exist (never the built-in one).
        known = [q for q in known if q.isSystem or q.folderName in on_disk]

        # Surface the user's original app data — visible, launchable, protected. — visible, launchable, protected.
        if not any(q.isSystem for q in known) and system_data_dir_for(app).exists():
            known.insert(0, Profile(
                folderName=system_marker_for(app),
                displayName=system_display_name_for(app),
                app=app,
                colorHex="#3B82F6",
                isPinned=True,
                isSystem=True,
            ))
        return known

    def save_metadata(self):
        for app in APPS:
            app_dir = profiles_dir_for(app)
            app_dir.mkdir(parents=True, exist_ok=True)
            (app_dir / ".profiles.json").write_text(json.dumps(
                [q.to_json() for q in self.profiles
                 if normalize_app(q.app) == app],
                indent=2, ensure_ascii=False))

    # -- CRUD

    def unique_folder_name(self, base: str, app: str | None = None) -> str:
        folder, counter = base, 2
        existing = {p.folderName.lower() for p in self.profiles}
        reserved = {SYSTEM_FOLDER_NAME, SYSTEM_CODE_FOLDER_NAME,
                    SYSTEM_DESKTOP_FOLDER_NAME, SYSTEM_GROK_FOLDER_NAME}
        # A carry-over still copying has claimed its folder on disk already.
        while (folder.lower() in existing or folder in reserved
               or (app and (profiles_dir_for(app) / folder).exists())):
            folder = f"{base}-{counter}"
            counter += 1
        return folder

    def create(self, name, color_hex, memory_mb, project_path, app=APP_CURSOR):
        app = normalize_app(app)
        base = sanitize_folder_name(name.replace(" ", "_"))
        if not base:
            self.on_error("Profile name must contain at least one letter, number, hyphen or underscore.")
            return None
        profile = Profile(
            folderName=self.unique_folder_name(base),
            displayName=name.strip(),
            app=app,
            colorHex=color_hex,
            defaultMemoryMB=memory_mb,
            defaultProjectPath=project_path or None,
        )
        profile_dir = self.directory_for(profile)
        try:
            profile_dir.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            self.on_error(f"Could not create profile folder: {e}")
            return None
        self.profiles.append(profile)
        self.save_metadata()
        self.on_changed()
        self.refresh_sizes()
        TitleBarColorizer.apply(profile, profile_dir)
        self.wire_brain_if_enabled(profile)
        return profile

    # -- Second brain

    def brainium(self):
        return Brainium.resolve(self.settings.get("brainiumPath", ""), self.settings.get("nodePath", ""))

    def _brain_targets(self, profiles=None):
        return [(normalize_app(p.app), str(self.directory_for(p)), p.isSystem)
                for p in (self.profiles if profiles is None else profiles)]

    def brain_task(self, label, work, on_done=None):
        """Run work(brainium) off the main loop; report via on_info/on_error."""
        b = self.brainium()
        if b is None:
            self.on_error(BRAINIUM_NOT_FOUND)
            return

        def run():
            try:
                result, error = work(b), None
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as e:
                result, error = None, str(e)

            def finish():
                if error:
                    self.on_error(f"{label}: {error}")
                elif on_done:
                    on_done(result)
                elif result:
                    self.on_info(result)
                return False

            GLib.idle_add(finish)

        threading.Thread(target=run, daemon=True).start()

    def wire_all_brains(self, enable=True):
        targets = self._brain_targets()
        self.brain_task("Wiring failed" if enable else "Unwiring failed",
                        lambda b: b.wire_all(targets, enable))

    def refresh_brain_status(self):
        """Fetch `brainium status` off the main loop, then refresh the UI."""
        b = self.brainium()
        if b is None:
            self.brain_status = None
            self.on_status()
            return

        def run():
            try:
                status = b.status()
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
                status = None

            def finish():
                self.brain_status = status
                self.on_status()
                return False
            GLib.idle_add(finish)

        threading.Thread(target=run, daemon=True).start()

    def wire_brain(self, profile: Profile):
        """Wire one profile now (Grok Bot has nothing local to wire)."""
        if brain_wire_args(profile.app, "", False, False) is None:
            return
        targets = self._brain_targets([profile])
        self.brain_task(f"Couldn't wire '{profile.displayName}'",
                        lambda b: (b.wire_all(targets, True), f"Wired '{profile.displayName}' into your second brain.")[1])

    def install_brainium(self, on_done=None):
        """Clone Brainium into ~/brainium (git), or unpack the GitHub tarball."""
        target = Path.home() / "brainium"

        def run():
            error = None
            try:
                if (target / "bin" / "brainium.mjs").is_file():
                    pass
                elif target.exists() and any(target.iterdir()):
                    raise RuntimeError(f"{target} already exists and isn't Brainium. Move it aside, "
                                       "or set its path below.")
                elif shutil.which("git"):
                    if target.exists():
                        target.rmdir()
                    proc = subprocess.run(["git", "clone", "--depth", "1", BRAINIUM_REPO, str(target)],
                                          capture_output=True, text=True, timeout=300)
                    if proc.returncode != 0:
                        raise RuntimeError(proc.stderr.strip().splitlines()[-1] if proc.stderr.strip()
                                           else "git clone failed")
                else:
                    import tarfile
                    import tempfile
                    import urllib.request
                    with tempfile.TemporaryDirectory() as tmp:
                        archive = Path(tmp) / "brainium.tar.gz"
                        urllib.request.urlretrieve(BRAINIUM_TARBALL, archive)
                        with tarfile.open(archive) as tar:
                            tar.extractall(tmp, filter="data")
                        root = next(d for d in Path(tmp).iterdir() if d.is_dir())
                        if target.exists():
                            target.rmdir()
                        shutil.move(str(root), str(target))
                if not (target / "bin" / "brainium.mjs").is_file():
                    raise RuntimeError(f"Downloaded Brainium, but {target}/bin/brainium.mjs is missing.")
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, StopIteration) as e:
                error = str(e) or type(e).__name__

            def finish():
                if error:
                    self.on_error(f"Couldn't install Brainium: {error}")
                else:
                    self.on_info(f"Brainium is ready at {target}.")
                self.refresh_brain_status()
                if on_done:
                    on_done()
                return False
            GLib.idle_add(finish)

        threading.Thread(target=run, daemon=True).start()

    def wire_brain_if_enabled(self, profile: Profile):
        if not self.settings.get("brainAutoWire") or brain_wire_args(profile.app, "", False, False) is None:
            return
        targets = self._brain_targets([profile])
        self.brain_task(f"Couldn't wire '{profile.displayName}'", lambda b: b.wire_all(targets, True),
                        on_done=lambda _r: None)

    def set_brain_config(self, pairs):
        """`brainium config set` for each pair in order, in one task (the config
        file is read-modify-written). Capture changes re-wire Claude Code hooks."""
        targets = (self._brain_targets([p for p in self.profiles if normalize_app(p.app) == APP_CODE])
                   if any(k == "capture" for k, _ in pairs) else [])

        def work(b):
            for key, value in pairs:
                b.run("config", "set", key, value)
            if targets:
                b.wire_all(targets, True)
            return "Saved."

        self.brain_task("Couldn't save the setting", work)

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
            LauncherBuilder.create_or_update(profile, self.directory_for(profile),
                                             self.cursor_path, self.code_path,
                                             self.desktop_path, self.grok_path)
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

    def create_overflow(self, name: str, color_hex: str, memory_mb: int,
                        project_path, source: Profile):
        """New profile as an overflow account of source (same app): its config,
        never its sign-in. The card appears when the copy finishes; the source
        card shows a spinner meanwhile."""
        app = normalize_app(source.app)
        base = sanitize_folder_name(name.replace(" ", "_"))
        if not base:
            self.on_error("Profile name must contain at least one letter, number, hyphen or underscore.")
            return
        self._start_carry_over(source, Profile(
            folderName=self.unique_folder_name(base, app), displayName=name.strip(),
            app=app, colorHex=color_hex, defaultMemoryMB=memory_mb,
            defaultProjectPath=project_path or None))

    def new_overflow(self, source: Profile):
        """One-click overflow account from a card's menu."""
        app = normalize_app(source.app)
        name = ((app_label(app) if source.isSystem else source.displayName)
                + (" 2" if app == APP_GROK else " Overflow"))
        self._start_carry_over(source, Profile(
            folderName=self.unique_folder_name(sanitize_folder_name(name.replace(" ", "-")), app),
            displayName=name, app=app, colorHex=source.colorHex,
            defaultMemoryMB=source.defaultMemoryMB,
            defaultProjectPath=source.defaultProjectPath))

    def _start_carry_over(self, source: Profile, new_profile: Profile):
        app = normalize_app(source.app)
        src_dir = self.directory_for(source)
        dest = profiles_dir_for(app) / new_profile.folderName
        self.duplicating.add(source.folderName)
        self.on_status()

        def work():
            error = None
            try:
                dest.mkdir(parents=True, exist_ok=True)
                carry_over(app, src_dir, source.isSystem, dest)
            except (OSError, ValueError, shutil.Error) as e:
                error = str(e)
                shutil.rmtree(dest, ignore_errors=True)

            def finish():
                self.duplicating.discard(source.folderName)
                if error:
                    self.on_error(f"Could not carry over from '{source.displayName}': {error}")
                    self.on_status()
                else:
                    self.profiles.append(new_profile)
                    self.save_metadata()
                    self.on_changed()
                    self.refresh_sizes()
                    # Copied Cursor settings carry the source's title bar color.
                    TitleBarColorizer.apply(new_profile, dest)
                    self.wire_brain_if_enabled(new_profile)
                return False

            GLib.idle_add(finish)

        threading.Thread(target=work, daemon=True).start()

    def duplicate(self, profile: Profile):
        """Clone a profile. For the built-in profile the original is only read.
        Desktop and Grok Bot duplicates are overflow accounts (config, never
        the sign-in; full Electron dirs are gigabytes of cache); Code/Cursor
        duplicates copy the whole folder."""
        app = normalize_app(profile.app)
        if app in (APP_GROK, APP_DESKTOP):
            self.new_overflow(profile)
            return
        if profile.isSystem:
            base = {APP_CODE: "Main-Claude-Code-Clone",
                    APP_DESKTOP: "Main-Claude-Desktop-Clone"}.get(app, "Main-Cursor-Clone")
            display = system_display_name_for(app) + " Clone"
        else:
            base = profile.folderName + "-copy"
            display = profile.displayName + " Copy"
        folder = self.unique_folder_name(base)
        source, dest = self.directory_for(profile), profiles_dir_for(app) / folder
        copy = Profile(
            folderName=folder,
            displayName=display,
            app=app,
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
            self.on_error("The built-in profile can't be deleted from here — it's your original app data.")
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
        app = normalize_app(profile.app)
        if app == APP_CODE:
            self.launch_code(profile, project_path)
        elif app == APP_DESKTOP:
            self.launch_desktop(profile, new_window)
        elif app == APP_GROK:
            # No --new-window switch: a second launch focuses the instance.
            self.launch_grok(profile)
        else:
            self.launch_cursor(profile, project_path, memory_mb, new_window)
        GLib.timeout_add_seconds(2, lambda: (self.refresh_running(), False)[1])

    def launch_cursor(self, profile: Profile, project_path=None, memory_mb=None, new_window=False):
        exe = self.cursor_path
        if not exe:
            self.on_error("Cursor could not be found. Install it from cursor.sh or set a custom path in Preferences.")
            return
        args = [exe]
        if not profile.isSystem:
            profile_dir = self.directory_for(profile)
            profile_dir.mkdir(parents=True, exist_ok=True)
            args += ["--user-data-dir", str(profile_dir)]
            # Idempotent: also covers profiles adopted from disk that never went through create().
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

    def launch_desktop(self, profile: Profile, new_window=False):
        exe = self.desktop_path
        if not exe:
            self.on_error("Claude Desktop could not be found. Install it or set a custom path in Preferences.")
            return
        args = [exe]
        if not profile.isSystem:
            # Chromium switches need "--user-data-dir=<path>" (a separate
            # value isn't parsed). Verified on Windows with the standalone
            # build; not yet verified on Linux packages.
            profile_dir = self.directory_for(profile)
            profile_dir.mkdir(parents=True, exist_ok=True)
            args.append(f"--user-data-dir={profile_dir}")
        if new_window:
            args.append("--new-window")
        try:
            subprocess.Popen(args, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.on_error(f"Failed to launch Claude Desktop: {e}")
            return
        profile.lastLaunchedAt = datetime.now(timezone.utc)
        self.save_metadata()
        self.on_status()

    def launch_grok(self, profile: Profile):
        exe = self.grok_path
        if not exe:
            self.on_error("Grok Bot could not be found. Install it or set a custom path in Preferences.")
            return
        args = [exe]
        # Never leak a stray isolation switch from our own environment.
        env = {k: v for k, v in os.environ.items()
               if k not in (GROK_USER_DATA_ENV, "SAND_DATA_ROOT")}
        if not profile.isSystem:
            profile_dir = self.directory_for(profile)
            profile_dir.mkdir(parents=True, exist_ok=True)
            env[GROK_USER_DATA_ENV] = str(profile_dir)
            args.append(f"--user-data-dir={profile_dir}")
        try:
            subprocess.Popen(args, env=env, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.on_error(f"Failed to launch Grok Bot: {e}")
            return
        profile.lastLaunchedAt = datetime.now(timezone.utc)
        self.save_metadata()
        self.on_status()

    def launch_code(self, profile: Profile, project_path=None):
        exe = self.code_path
        if not exe:
            self.on_error("Claude Code could not be found. Install it (see code.claude.com/docs) "
                          "or set a custom path in Preferences.")
            return
        profile_dir = self.directory_for(profile)
        if not profile.isSystem:
            profile_dir.mkdir(parents=True, exist_ok=True)
        work = project_path or profile.defaultProjectPath or str(Path.home())
        # The CLI is interactive: open a real terminal with CLAUDE_CONFIG_DIR
        # set so login prompts stay visible. First launch walks through login.
        terminal = self.find_terminal()
        if not terminal:
            self.on_error(
                "No terminal emulator found. Run this yourself: "
                f'CLAUDE_CONFIG_DIR="{profile_dir}" {exe}')
            return
        env = "".join(f'{k}="{v}" ' for k, v in Endpoint().claude_code_env(profile.endpointIdentity).items())
        cmd = (f'CLAUDE_CONFIG_DIR="{profile_dir}" {env}exec "{exe}"; '
               f'echo; echo "[Prism] session ended - press Enter to close."; read _')
        try:
            subprocess.Popen([*terminal, "sh", "-c", cmd], cwd=work,
                             start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.on_error(f"Failed to launch Claude Code: {e}")
            return
        profile.lastLaunchedAt = datetime.now(timezone.utc)
        self.save_metadata()
        self.on_status()

    @staticmethod
    def find_terminal():
        """A terminal emulator argv prefix, or None. Covers the common Linux
        desktops; GNOME/KDE/Xfce/VTE-based fallbacks in order."""
        candidates = [
            ["x-terminal-emulator", "-e"],
            ["gnome-terminal", "--"],
            ["konsole", "-e"],
            ["xfce4-terminal", "-e"],
            ["mate-terminal", "-e"],
            ["kgx", "-e"],
            ["alacritty", "-e"],
            ["kitty", "--"],
            ["foot", "-e"],
            ["xterm", "-e"],
        ]
        for argv in candidates:
            if shutil.which(argv[0]):
                return argv
        return None

    def quit_profile(self, profile: Profile):
        for pid in self.running.get(profile.folderName, []):
            if pid <= 0:
                continue  # sentinel marker, not a real process
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
        snapshot = [(p.folderName, str(self.directory_for(p)), p.isSystem,
                     normalize_app(p.app)) for p in self.profiles]

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
                # Never match ourselves: this file is prism.py, and a dev
                # checkout could otherwise look Cursor-adjacent. (The macOS
                # app once SIGTERM'd itself this way — same guard here.)
                if "prism" in exe:
                    return False
                looks_like_cursor = exe == "cursor" or exe.endswith(".appimage") and "cursor" in exe
                return looks_like_cursor and not any(a.startswith("--type=") for a in argv)

            def is_desktop_main(argv):
                exe = os.path.basename(argv[0]).lower()
                if "prism" in exe:
                    return False
                joined = "\0".join(argv).lower()
                if "claude-code" in joined:
                    # Bundled CLI helper shares the Desktop's process family.
                    return False
                # No bare-`claude` fallback: that name belongs to the Code CLI,
                # which would otherwise light up the built-in Desktop profile.
                looks = exe == "claude-desktop"
                return looks and not any(a.startswith("--type=") for a in argv)

            def is_grok_main(argv):
                exe = os.path.basename(argv[0]).lower()
                if "prism" in exe or exe not in ("grok-bot", "grok bot"):
                    return False
                # The local-exec daemon and agent coordinator run through the
                # same executable with a .cjs entry script; helpers carry --type=.
                return not any(a.startswith("--type=") or a.endswith(".cjs")
                               or "app.asar" in a for a in argv[1:])

            def user_data_dir(argv):
                for a in argv:
                    if a.startswith("--user-data-dir="):
                        return a.split("=", 1)[1]
                if "--user-data-dir" in argv:
                    nxt = argv[argv.index("--user-data-dir") + 1:argv.index("--user-data-dir") + 2]
                    return nxt[0] if nxt else None
                return None

            any_desktop = any(is_desktop_main(argv) for _, argv in processes)
            result = {}
            for name, directory, is_system, app in snapshot:
                if app == APP_CODE:
                    # The CLI is a terminal session, not a trackable GUI app.
                    result[name] = []
                elif app == APP_DESKTOP:
                    if is_system:
                        result[name] = [
                            pid for pid, argv in processes
                            if is_desktop_main(argv) and user_data_dir(argv) is None]
                    else:
                        result[name] = [
                            pid for pid, argv in processes
                            if is_desktop_main(argv) and user_data_dir(argv) == directory]
                    if (not result[name] and any_desktop
                            and os.path.isfile(os.path.join(directory, "lockfile"))):
                        # Electron holds a lockfile in a live user-data-dir.
                        # -1 is a sentinel, never signaled (see quit_profile).
                        result[name] = [-1]
                elif app == APP_GROK:
                    want = None if is_system else directory
                    result[name] = [pid for pid, argv in processes
                                    if is_grok_main(argv) and user_data_dir(argv) == want]
                elif is_system:
                    result[name] = [pid for pid, argv in processes
                                    if is_cursor_main(argv) and "--user-data-dir" not in argv]
                else:
                    result[name] = [
                        pid for pid, argv in processes
                        if is_cursor_main(argv) and user_data_dir(argv) == directory
                    ]

            # Live RSS: VmRSS of matched PIDs only (cheap, no new deps).
            live = {}
            for name, pids in result.items():
                total = 0
                for pid in pids:
                    if pid > 0:
                        total += rss_of_pid(pid)
                live[name] = total

            # System CPU % from /proc/stat deltas (None on first sample).
            cpu = None
            try:
                with open("/proc/stat", encoding="utf-8") as f:
                    nums = [int(x) for x in f.readline().split()[1:9]]
                idle, total_ticks = nums[3] + nums[4], sum(nums)
                with self._cpu_lock:
                    prev = self._prev_cpu
                    self._prev_cpu = (idle, total_ticks)
                if prev is not None:
                    idle_d, total_d = idle - prev[0], total_ticks - prev[1]
                    if total_d > 0:
                        cpu = max(0.0, min(100.0, (total_d - idle_d) / total_d * 100.0))
            except (OSError, ValueError, IndexError):
                pass

            def apply():
                self.running = result
                self.live_bytes = live
                self.system_cpu = cpu
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

# ---------------------------------------------------------------------------
# Look: quiet neutrals, one accent, hairline borders. Follows the system
# light/dark setting; colours match the macOS and Windows apps.
# ---------------------------------------------------------------------------

THEMES = {
    False: {  # light
        "bg": "#FFFFFF", "sidebar": "#F7F7F8", "panel": "#FCFCFD", "card": "#FFFFFF",
        "border": "#E6E6EA", "subtle": "#EFEFF2", "border_med": "#DCDCE1",
        "text": "#18181B", "text2": "#52525C", "text3": "#6B6B75",
        "field": "#F1F1F3", "hover": "#F4F4F6", "selected": "#E9E9EC",
        "accent": "#5B5BD6", "accent_text": "#4F4FC4", "accent_soft": "alpha(#5B5BD6, 0.08)",
        "accent_ring": "alpha(#5B5BD6, 0.24)", "green": "#15803D", "live": "#22C55E",
    },
    True: {  # dark
        "bg": "#141416", "sidebar": "#19191C", "panel": "#17171A", "card": "#1C1C20",
        "border": "#2A2A2F", "subtle": "#222227", "border_med": "#34343A",
        "text": "#EDEDF0", "text2": "#A9A9B3", "text3": "#8C8C97",
        "field": "#222227", "hover": "#1F1F23", "selected": "#2A2A30",
        "accent": "#6262D9", "accent_text": "#A5A5F3", "accent_soft": "alpha(#6262D9, 0.16)",
        "accent_ring": "alpha(#6262D9, 0.35)", "green": "#4ADE80", "live": "#22C55E",
    },
}

# Line icons on a 20x20 grid (stroked): the same shapes as the other apps.
# Generic, not app logos.
ICON_PATHS = {
    APP_CURSOR: "M5,3.5 L15.5,8.5 L11,10 L9.5,14.5 Z",
    APP_CODE: ("M4.5,4 H15.5 A2,2 0 0 1 17.5,6 V14 A2,2 0 0 1 15.5,16 H4.5 A2,2 0 0 1 2.5,14 V6 "
               "A2,2 0 0 1 4.5,4 Z M6,8.5 L8.5,10.5 L6,12.5 M10.5,12.5 H14"),
    APP_DESKTOP: ("M4.5,3.5 H15.5 A2,2 0 0 1 17.5,5.5 V12 A2,2 0 0 1 15.5,14 H4.5 A2,2 0 0 1 2.5,12 "
                  "V5.5 A2,2 0 0 1 4.5,3.5 Z M7,17 H13 M10,14 V17"),
    APP_GROK: ("M6.5,6.5 H13.5 A3,3 0 0 1 16.5,9.5 V13 A3,3 0 0 1 13.5,16 H6.5 A3,3 0 0 1 3.5,13 "
               "V9.5 A3,3 0 0 1 6.5,6.5 Z M10,3.5 V6.5 M7.5,10.7 V11.3 M12.5,10.7 V11.3"),
    "stack": "M10,3 L17,7 L10,11 L3,7 Z M3,11 L10,15 L17,11",
    "pulse": "M2.5,10 H5.5 L7.5,5 L11.5,15 L13.5,10 H17.5",
    "person": "M10,4 A3,3 0 1 1 9.99,4 Z M4,16.5 C5,13.5 7.5,12 10,12 C12.5,12 15,13.5 16,16.5",
    "brain": ("M8,3.5 A2.5,2.5 0 0 0 5.5,6 V6.3 A2.6,2.6 0 0 0 4,10.7 A2.6,2.6 0 0 0 6,14.9 "
              "A2.5,2.5 0 0 0 10,16 V5.5 A2,2 0 0 0 8,3.5 Z M12,3.5 A2.5,2.5 0 0 1 14.5,6 V6.3 "
              "A2.6,2.6 0 0 1 16,10.7 A2.6,2.6 0 0 1 14,14.9 A2.5,2.5 0 0 1 10,16"),
    "search": "M9,3.5 A5.5,5.5 0 1 1 8.99,3.5 Z M13,13 L16.5,16.5",
    "arrow": "M4,10 H15 M11,6 L15,10 L11,14",
    "folder": ("M3,6.5 A1.5,1.5 0 0 1 4.5,5 H8 L9.5,6.5 H15.5 A1.5,1.5 0 0 1 17,8 V14.5 "
               "A1.5,1.5 0 0 1 15.5,16 H4.5 A1.5,1.5 0 0 1 3,14.5 Z"),
    "pin": "M10,13 V17.5 M6,13 H14 L12.5,9 V4.5 H7.5 V9 Z",
    "plus": "M10,4.5 V15.5 M4.5,10 H15.5",
    "endpoint": "M3,6 H13 M10,3 L13,6 L10,9 M17,14 H7 M10,11 L7,14 L10,17",
}

_PATH_TOKEN = re.compile(r"[MLHVCAZmlhvcaz]|-?\d*\.?\d+(?:e-?\d+)?")


def _parse_path(d: str):
    """Absolute SVG path commands (M L H V C A Z) as (cmd, [numbers])."""
    out, cmd, nums = [], None, []
    for tok in _PATH_TOKEN.findall(d):
        if tok.isalpha():
            if cmd:
                out.append((cmd, nums))
            cmd, nums = tok, []
        else:
            nums.append(float(tok))
    if cmd:
        out.append((cmd, nums))
    return out


def _arc_to_cairo(cr, x1, y1, r, large, sweep, x2, y2):
    """SVG circular arc (rx = ry = r, no rotation) from (x1,y1) to (x2,y2)."""
    import math
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    d2 = dx * dx + dy * dy
    if d2 == 0:
        return
    r = max(r, math.sqrt(d2))
    coef = math.sqrt(max(0.0, (r * r - d2) / d2))
    if large == sweep:
        coef = -coef
    cx = (x1 + x2) / 2 + coef * dy
    cy = (y1 + y2) / 2 - coef * dx
    a1 = math.atan2(y1 - cy, x1 - cx)
    a2 = math.atan2(y2 - cy, x2 - cx)
    (cr.arc if sweep else cr.arc_negative)(cx, cy, r, a1, a2)


class LineIcon(Gtk.DrawingArea):
    """A stroked line icon drawn with Cairo on a 20x20 grid (no SVG loader needed)."""

    def __init__(self, name: str, color: str, size: int = 16, width: float = 1.6):
        super().__init__(content_width=size, content_height=size,
                         halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        self._commands = _parse_path(ICON_PATHS[name])
        rgba = Gdk.RGBA()
        rgba.parse(color)
        self._rgba, self._width = rgba, width
        self.set_draw_func(self._draw)

    def _draw(self, _area, cr, w, h):
        scale = min(w, h) / 20.0
        cr.scale(scale, scale)
        cr.set_line_width(self._width)
        cr.set_line_cap(1)   # round
        cr.set_line_join(1)  # round
        cr.set_source_rgba(self._rgba.red, self._rgba.green, self._rgba.blue, self._rgba.alpha)
        x = y = sx = sy = 0.0
        for cmd, n in self._commands:
            if cmd == "M":
                x, y = n[0], n[1]
                sx, sy = x, y
                cr.move_to(x, y)
                for i in range(2, len(n), 2):
                    x, y = n[i], n[i + 1]
                    cr.line_to(x, y)
            elif cmd == "L":
                for i in range(0, len(n), 2):
                    x, y = n[i], n[i + 1]
                    cr.line_to(x, y)
            elif cmd == "H":
                for v in n:
                    x = v
                    cr.line_to(x, y)
            elif cmd == "V":
                for v in n:
                    y = v
                    cr.line_to(x, y)
            elif cmd == "C":
                for i in range(0, len(n), 6):
                    cr.curve_to(*n[i:i + 6])
                    x, y = n[i + 4], n[i + 5]
            elif cmd == "A":
                for i in range(0, len(n), 7):
                    r, _ry, _rot, large, sweep, x2, y2 = n[i:i + 7]
                    _arc_to_cairo(cr, x, y, r, int(large), int(sweep), x2, y2)
                    x, y = x2, y2
            elif cmd in "Zz":
                cr.close_path()
                x, y = sx, sy
        cr.stroke()


try:  # Drawing from Python needs PyGObject's cairo glue (python3-gi-cairo on Debian/Ubuntu).
    import gi._gi_cairo  # noqa: F401
    HAS_GI_CAIRO = cairo is not None
except ImportError:
    HAS_GI_CAIRO = False


def line_icon(name: str, color: str, size: int = 16, width: float = 1.6) -> Gtk.Widget:
    """The icon, or an empty spacer of the same size when Cairo glue is missing."""
    if HAS_GI_CAIRO:
        return LineIcon(name, color, size, width)
    return Gtk.Box(width_request=size, height_request=size, valign=Gtk.Align.CENTER)


def theme_colors() -> dict:
    return THEMES[Adw.StyleManager.get_default().get_dark()]


class MainWindow(Adw.ApplicationWindow):
    """Sidebar (search, filters, second brain, totals) | profile list grouped
    into Running / Not running | detail panel for the selected profile."""

    SORT_MODES = ["Recent", "Name", "Size"]
    FILTERS = [("All profiles", "stack"), ("Running", "pulse"), ("Custom", "person"),
               ("Cursor", APP_CURSOR), ("Claude Code", APP_CODE),
               ("Claude Desktop", APP_DESKTOP), ("Grok Bot", APP_GROK)]
    INSPECTOR_MIN_WIDTH = 1180

    def __init__(self, app, store: Store):
        super().__init__(application=app, title="Prism", default_width=1240, default_height=780)
        self.store = store
        self.search_text = ""
        self.sort_mode = 0
        self.filter_mode = 0  # 0 all, 1 running, 2 custom, 3 cursor, 4 code, 5 desktop, 6 grok
        self.selected: str | None = None  # folderName
        self._running_set = set()
        self.status_updaters = []
        self.inspector_updaters = []
        self.add_css_class("prism")

        self._css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), self._css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        Adw.StyleManager.get_default().connect("notify::dark", lambda *_: self.rebuild())

        store.on_changed = self.rebuild
        store.on_status = self.refresh_status
        store.on_error = self.show_error
        store.on_info = self.show_info

        self.toasts = Adw.ToastOverlay()
        self.set_content(self.toasts)
        root = Adw.ToolbarView()
        self.toasts.set_child(root)

        header = Adw.HeaderBar()
        self.title_lbl = Gtk.Label(label="All profiles")
        self.title_lbl.add_css_class("prism-title")
        self.title_count = Gtk.Label()
        self.title_count.add_css_class("prism-dim")
        title_box = Gtk.Box(spacing=10, margin_start=6)
        title_box.append(self.title_lbl)
        title_box.append(self.title_count)
        header.pack_start(title_box)
        header.set_title_widget(Gtk.Box())
        new_btn = Gtk.Button(tooltip_text="New profile (Ctrl+N)")
        new_box = Gtk.Box(spacing=6)
        self.new_icon_slot = new_box
        new_box.append(Gtk.Label(label="New profile"))
        new_btn.set_child(new_box)
        new_btn.add_css_class("suggested-action")
        new_btn.connect("clicked", lambda *_: self.new_profile())
        header.pack_end(new_btn)
        self.sort_btn = Gtk.Button(label="Recent ▾", tooltip_text="Sort profiles")
        self.sort_btn.add_css_class("flat")
        self.sort_btn.connect("clicked", self.on_sort)
        header.pack_end(self.sort_btn)
        root.add_top_bar(header)

        body = Gtk.Box()
        root.set_content(body)

        # -- Sidebar
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, width_request=228, hexpand=False)
        side.add_css_class("prism-sidebar")
        body.append(side)
        search_box = Gtk.Box(spacing=8, margin_top=12, margin_start=12, margin_end=12)
        search_box.add_css_class("prism-search")
        self.search_icon_slot = search_box
        self.search = Gtk.Text(placeholder_text="Search", hexpand=True, width_chars=6)
        self.search.connect("changed", self.on_search)
        search_box.append(self.search)
        side.append(search_box)

        self.nav_buttons = []
        self.nav_counts = []
        nav = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, margin_top=14,
                      margin_start=12, margin_end=12)
        for i, (label, icon) in enumerate(self.FILTERS):
            if i == 3:
                apps = Gtk.Label(label="Apps", xalign=0, margin_top=14, margin_bottom=4, margin_start=10)
                apps.add_css_class("prism-section-title")
                nav.append(apps)
            btn = Gtk.Button()
            btn.add_css_class("prism-nav")
            row = Gtk.Box(spacing=10)
            row.append(Gtk.Box(width_request=16))  # icon slot, filled by restyle()
            row.append(Gtk.Label(label=label, xalign=0, hexpand=True))
            count = Gtk.Label()
            count.add_css_class("prism-count")
            row.append(count)
            btn.set_child(row)
            btn.connect("clicked", lambda *_, m=i: self.set_filter(m))
            nav.append(btn)
            self.nav_buttons.append(btn)
            self.nav_counts.append(count)
        side.append(nav)
        side.append(Gtk.Box(vexpand=True))

        self.brain_card = Gtk.Button(margin_start=12, margin_end=12, tooltip_text="Second brain settings")
        self.brain_card.add_css_class("prism-brain-card")
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        top = Gtk.Box(spacing=8)
        self.brain_icon_slot = top
        brain_lbl = Gtk.Label(label="Second brain", xalign=0, hexpand=True)
        brain_lbl.add_css_class("prism-strong")
        top.append(brain_lbl)
        self.brain_dot = Gtk.Box(valign=Gtk.Align.CENTER)
        top.append(self.brain_dot)
        self.brain_state = Gtk.Label(label="Off")
        self.brain_state.add_css_class("prism-small")
        top.append(self.brain_state)
        card.append(top)
        self.brain_detail = Gtk.Label(label="Not set up", xalign=0, ellipsize=Pango.EllipsizeMode.MIDDLE)
        self.brain_detail.add_css_class("prism-small")
        card.append(self.brain_detail)
        self.brain_card.set_child(card)
        self.brain_card.connect("clicked", lambda *_: self.open_preferences(brain=True))
        side.append(self.brain_card)

        self.endpoint = Endpoint()
        self.endpoint_card = Gtk.Button(margin_start=12, margin_end=12, margin_top=8,
                                        tooltip_text="Endpoint: a local API that switches accounts (Ctrl+I switches identity)")
        self.endpoint_card.add_css_class("prism-brain-card")
        ecard = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        etop = Gtk.Box(spacing=8)
        self.endpoint_icon_slot = etop
        elbl = Gtk.Label(label="Endpoint", xalign=0, hexpand=True)
        elbl.add_css_class("prism-strong")
        etop.append(elbl)
        self.endpoint_dot = Gtk.Box(valign=Gtk.Align.CENTER)
        self.endpoint_dot.add_css_class("prism-off")
        etop.append(self.endpoint_dot)
        self.endpoint_state = Gtk.Label(label="Off")
        self.endpoint_state.add_css_class("prism-small")
        etop.append(self.endpoint_state)
        ecard.append(etop)
        self.endpoint_detail = Gtk.Label(label="Not set up", xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self.endpoint_detail.add_css_class("prism-small")
        ecard.append(self.endpoint_detail)
        self.endpoint_card.set_child(ecard)
        self.endpoint_card.connect("clicked", lambda *_: self.open_preferences(endpoint=True))
        side.append(self.endpoint_card)

        foot = Gtk.Box(margin_top=10, margin_bottom=12, margin_start=16, margin_end=8)
        totals = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True)
        self.running_lbl = Gtk.Label(xalign=0)
        self.running_lbl.add_css_class("prism-small")
        self.system_lbl = Gtk.Label(xalign=0)
        self.system_lbl.add_css_class("prism-small")
        totals.append(self.running_lbl)
        totals.append(self.system_lbl)
        foot.append(totals)
        prefs = Gtk.Button(icon_name="emblem-system-symbolic", tooltip_text="Preferences",
                           valign=Gtk.Align.END)
        prefs.add_css_class("flat")
        prefs.connect("clicked", lambda *_: self.open_preferences())
        foot.append(prefs)
        side.append(foot)

        # -- Main column
        main = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True)
        body.append(main)
        self.banner = Gtk.Box(spacing=10, margin_top=12, margin_start=16, margin_end=16)
        self.banner.add_css_class("prism-banner")
        banner_lbl = Gtk.Label(label="Cursor wasn't found. Install it from cursor.com, or set its path in Preferences.",
                               xalign=0, wrap=True, hexpand=True)
        banner_lbl.add_css_class("prism-sub")
        self.banner.append(banner_lbl)
        banner_btn = Gtk.Button(label="Preferences", valign=Gtk.Align.CENTER)
        banner_btn.add_css_class("prism-secondary")
        banner_btn.connect("clicked", lambda *_: self.open_preferences())
        self.banner.append(banner_btn)
        main.append(self.banner)

        # New Prism release (checked once at startup).
        self.update_banner = Gtk.Box(spacing=10, margin_top=12, margin_start=16, margin_end=16, visible=False)
        self.update_banner.add_css_class("prism-banner")
        self.update_label = Gtk.Label(xalign=0, wrap=True, hexpand=True)
        self.update_banner.append(self.update_label)
        later = Gtk.Button(label="Later", valign=Gtk.Align.CENTER)
        later.add_css_class("prism-quiet")
        later.connect("clicked", self.on_update_later)
        self.update_banner.append(later)
        get = Gtk.Button(label="Download", valign=Gtk.Align.CENTER)
        get.add_css_class("prism-secondary")
        get.connect("clicked", self.on_update_download)
        self.update_banner.append(get)
        main.append(self.update_banner)
        self._release = None

        self.columns = Gtk.Box(spacing=12, margin_top=14, margin_bottom=2, margin_start=46, margin_end=46)
        for text, width in (("Name", -1), ("App", 130), ("Status", 160), ("", 104)):
            lbl = Gtk.Label(label=text, xalign=0, hexpand=width < 0, width_request=max(width, 0))
            lbl.add_css_class("prism-colhead")
            self.columns.append(lbl)
        main.append(self.columns)

        self.scroller = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        main.append(self.scroller)
        self.list_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin_bottom=16)
        self.scroller.set_child(self.list_box)

        self.empty = Adw.StatusPage(
            icon_name="folder-templates-symbolic", title="No profiles yet",
            description="Each profile keeps its own sign-in, settings and history.", vexpand=True)
        empty_btn = Gtk.Button(label="New profile", halign=Gtk.Align.CENTER)
        empty_btn.add_css_class("suggested-action")
        empty_btn.add_css_class("pill")
        empty_btn.connect("clicked", lambda *_: self.new_profile())
        self.empty.set_child(empty_btn)
        main.append(self.empty)

        self.no_matches = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, vexpand=True,
                                  valign=Gtk.Align.CENTER, halign=Gtk.Align.CENTER)
        self.no_matches_lbl = Gtk.Label()
        self.no_matches_lbl.add_css_class("prism-sub")
        self.no_matches_btn = Gtk.Button(halign=Gtk.Align.CENTER)
        self.no_matches_btn.connect("clicked", lambda *_: self.clear_filters())
        self.no_matches.append(self.no_matches_lbl)
        self.no_matches.append(self.no_matches_btn)
        main.append(self.no_matches)

        # -- Detail panel
        self.inspector = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, width_request=320)
        self.inspector.add_css_class("prism-inspector")
        body.append(self.inspector)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key)
        self.add_controller(keys)
        self.connect("notify::default-width", lambda *_: self.update_layout())
        self.connect("notify::maximized", lambda *_: GLib.idle_add(self.update_layout))

        store.refresh_brain_status()
        self.rebuild()
        self.refresh_endpoint()
        GLib.timeout_add_seconds(5, self._endpoint_tick)
        self.check_for_update()

    # -- helpers

    def show_error(self, message):
        self.toasts.add_toast(Adw.Toast(title=message, timeout=5))

    def show_info(self, message):
        self.toasts.add_toast(Adw.Toast(title=message, timeout=6))

    def new_profile(self):
        EditorDialog(self, self.store, None).present()

    def open_preferences(self, brain=False, endpoint=False):
        dialog = PreferencesDialog(self, self.store)
        if brain:
            dialog.set_visible_page(dialog.brain_page)
        elif endpoint:
            dialog.set_visible_page(dialog.endpoint_page)
        dialog.present()

    def on_key(self, _ctrl, keyval, _code, state):
        if state & Gdk.ModifierType.CONTROL_MASK:
            if keyval in (Gdk.KEY_k, Gdk.KEY_K):
                self.search.grab_focus()
                return True
            if keyval in (Gdk.KEY_n, Gdk.KEY_N):
                self.new_profile()
                return True
            if keyval in (Gdk.KEY_i, Gdk.KEY_I):
                self.switch_endpoint_identity()
                return True
        return False

    # -- endpoint

    def refresh_endpoint(self):
        def done(status, _err):
            ep = self.endpoint
            if status is not None:
                on, label = True, "On"
                ids = status.get("identities") or []
                st = next((i for i in ids if i.get("active")), ids[0] if ids else None)
                if st is None:
                    detail = "No identities yet"
                else:
                    detail = f"{st.get('name', '')} · ${st.get('monthCost', 0):.2f} this month"
                    if st.get("cooldownUntil"):
                        detail += " · rate-limited"
            else:
                on = False
                label = "Stopped" if ep.config.get("enabled") else "Off"
                detail = "Not set up" if not ep.identities else f"{(ep.active or {}).get('name', '')} · not running"
            self.endpoint_state.set_label(label)
            for css, active in (("prism-live", on), ("prism-off", not on)):
                (self.endpoint_dot.add_css_class if active else self.endpoint_dot.remove_css_class)(css)
            self.endpoint_detail.set_label(detail)

        def work():
            self.endpoint.reload()
            return self.endpoint.status() if (self.endpoint.identities or self.endpoint.config.get("enabled")) else None
        run_in_background(work, done)

    def _endpoint_tick(self):
        self.refresh_endpoint()
        return True

    def switch_endpoint_identity(self):
        ep = self.endpoint
        ep.reload()
        if len(ep.identities) < 2:
            self.open_preferences(endpoint=True)
            return
        nxt = ep.identities[(ep.identities.index(ep.active) + 1) % len(ep.identities)]
        run_in_background(lambda: ep.set_active(nxt["id"]),
                          lambda *_: (self.refresh_endpoint(), self.toasts.add_toast(
                              Adw.Toast(title=f"Endpoint now uses {nxt.get('name', '')}", timeout=2))))

    # -- Prism updates

    def check_for_update(self):
        def work():
            release = github_latest_release()
            tag = release.get("tag_name") or ""
            if version_tuple(tag) > version_tuple(PRISM_VERSION):
                return release
            return None

        def done(release, _err):
            if not release or self.store.settings.get("skippedPrismVersion") == release.get("tag_name"):
                return
            self._release = release
            self.update_label.set_label(
                f"Prism {release['tag_name'].lstrip('v')} is available. You have {PRISM_VERSION}.")
            self.update_banner.set_visible(True)
        run_in_background(work, done)

    def on_update_download(self, *_):
        if self._release:
            Gio.AppInfo.launch_default_for_uri(
                self._release.get("html_url") or f"https://github.com/{GITHUB_REPO}/releases/latest", None)

    def on_update_later(self, *_):
        if self._release:
            self.store.settings["skippedPrismVersion"] = self._release.get("tag_name")
            self.store.save_settings()
        self.update_banner.set_visible(False)

    def on_search(self, entry):
        self.search_text = entry.get_text().strip().lower()
        self.rebuild()

    def on_sort(self, button):
        self.sort_mode = (self.sort_mode + 1) % len(self.SORT_MODES)
        button.set_label(f"{self.SORT_MODES[self.sort_mode]} ▾")
        self.rebuild()

    def set_filter(self, mode):
        self.filter_mode = mode
        self.rebuild()

    def clear_filters(self):
        if self.search_text:
            self.search.set_text("")
        else:
            self.set_filter(0)

    def is_running(self, p):
        return bool(self.store.running.get(p.folderName))

    def matches(self, p, mode):
        app = normalize_app(p.app)
        return {0: True, 1: self.is_running(p), 2: not p.isSystem,
                3: app == APP_CURSOR, 4: app == APP_CODE,
                5: app == APP_DESKTOP, 6: app == APP_GROK}[mode]

    def visible_profiles(self):
        def key(p: Profile):
            primary = (not p.isPinned, not p.isSystem)
            if self.sort_mode == 1:
                return (*primary, p.displayName.lower())
            if self.sort_mode == 2:
                return (*primary, -(self.store.sizes.get(p.folderName) or 0))
            stamp = p.lastLaunchedAt.timestamp() if p.lastLaunchedAt else 0
            return (*primary, -stamp)

        q = self.search_text
        return [p for p in sorted(self.store.profiles, key=key)
                if self.matches(p, self.filter_mode)
                and (not q or q in p.displayName.lower() or q in p.folderName.lower()
                     or q in app_label(normalize_app(p.app)).lower() or q in normalize_app(p.app))]

    def selected_profile(self):
        return next((p for p in self.store.profiles if p.folderName == self.selected), None)

    # -- styling

    def regenerate_css(self):
        c = theme_colors()
        rules = [
            f"@define-color accent_bg_color {c['accent']};",
            f"@define-color accent_color {c['accent_text']};",
            f"window.prism, window.prism .prism-main {{ background: {c['bg']}; color: {c['text']}; }}",
            f"window.prism headerbar {{ background: {c['bg']}; box-shadow: inset 0 -1px {c['subtle']}; }}",
            f".prism-title {{ font-size: 15px; font-weight: 600; color: {c['text']}; }}",
            f".prism-sidebar {{ background: {c['sidebar']}; border-right: 1px solid {c['border']}; }}",
            f".prism-inspector {{ background: {c['panel']}; border-left: 1px solid {c['border']}; }}",
            f".prism-search {{ background: {c['field']}; border-radius: 8px; padding: 0 10px; min-height: 30px; }}",
            f".prism-search text {{ background: none; color: {c['text']}; }}",
            f"button.prism-nav {{ background: none; box-shadow: none; border-radius: 7px; padding: 0 10px; "
            f"min-height: 30px; color: {c['text2']}; font-weight: normal; }}",
            f"button.prism-nav:hover {{ background: {c['hover']}; }}",
            f"button.prism-nav.selected {{ background: {c['selected']}; color: {c['text']}; font-weight: 500; }}",
            f".prism-count, .prism-dim, .prism-colhead, .prism-small {{ color: {c['text3']}; }}",
            ".prism-count { font-size: 12px; } .prism-small { font-size: 11px; }",
            ".prism-colhead { font-size: 11px; font-weight: 500; }",
            f".prism-section-title {{ font-size: 11px; font-weight: 600; color: {c['text3']}; }}",
            f".prism-section {{ font-size: 12px; font-weight: 600; color: {c['text']}; }}",
            f".prism-sub {{ color: {c['text2']}; }}",
            f".prism-strong {{ font-size: 12px; font-weight: 500; color: {c['text']}; }}",
            f".prism-row {{ border-radius: 8px; padding: 0 14px; min-height: 44px; "
            f"border: 1px solid transparent; }}",
            f".prism-row:hover {{ background: {c['hover']}; }}",
            f".prism-row.selected {{ background: {c['accent_soft']}; border-color: {c['accent_ring']}; }}",
            f".prism-name {{ font-weight: 500; color: {c['text']}; }}",
            f".prism-tag {{ font-size: 10.5px; color: {c['text3']}; border: 1px solid {c['border']}; "
            f"border-radius: 4px; padding: 0 5px; }}",
            f".prism-running {{ color: {c['green']}; font-weight: 500; }}",
            f".prism-live {{ background: {c['live']}; min-width: 6px; min-height: 6px; border-radius: 999px; "
            f"box-shadow: 0 0 0 3px alpha({c['live']}, 0.18); }}",
            f".prism-off {{ background: {c['text3']}; min-width: 6px; min-height: 6px; border-radius: 999px; }}",
            f"button.prism-quiet {{ background: none; box-shadow: none; color: {c['text2']}; "
            f"min-height: 28px; padding: 0 12px; border-radius: 6px; font-weight: normal; }}",
            f"button.prism-quiet:hover {{ background: {c['hover']}; color: {c['text']}; }}",
            f"button.prism-secondary {{ background: {c['card']}; color: {c['text']}; box-shadow: none; "
            f"border: 1px solid {c['border_med']}; min-height: 28px; padding: 0 12px; border-radius: 7px; "
            f"font-weight: 500; }}",
            f"button.prism-secondary:hover {{ background: {c['hover']}; }}",
            f"button.prism-primary {{ background: {c['accent']}; color: white; min-height: 32px; "
            f"border-radius: 7px; font-weight: 500; }}",
            f"button.prism-brain-card {{ background: {c['bg']}; border: 1px solid {c['border']}; "
            f"border-radius: 10px; padding: 9px 12px; box-shadow: none; font-weight: normal; }}",
            f"button.prism-brain-card:hover {{ background: {c['hover']}; }}",
            f"button.prism-footer {{ background: none; box-shadow: none; color: {c['text2']}; "
            f"min-height: 30px; padding: 0 12px; border-radius: 7px; font-weight: normal; }}",
            f"button.prism-footer:hover {{ background: {c['hover']}; }}",
            f".prism-rule {{ background: {c['subtle']}; min-height: 1px; }}",
            f".prism-banner {{ border: 1px solid {c['border']}; border-radius: 10px; padding: 8px 12px; }}",
            f".prism-key {{ color: {c['text3']}; font-size: 12px; }}",
            f".prism-value {{ color: {c['text']}; font-size: 12px; }}",
            f".prism-heading {{ font-size: 16px; font-weight: 600; color: {c['text']}; }}",
            ".swatch-selected { outline: 2px solid alpha(currentColor, 0.6); outline-offset: 2px; }",
        ]
        ep = getattr(self, "endpoint", None)
        endpoint_colors = {i.get("colorHex", "#64748B") for i in (ep.identities if ep else [])} | set(ENDPOINT_COLORS)
        for hex_color in {p.colorHex for p in self.store.profiles} | {h for _, h in PALETTE} | endpoint_colors:
            tag = hex_color.lstrip("#")
            rules.append(f".dot-{tag} {{ background: {hex_color}; min-width: 8px; min-height: 8px; "
                         "border-radius: 999px; }")
            rules.append(f".tile-{tag} {{ background: alpha({hex_color}, 0.14); border-radius: 11px; }}")
            rules.append(f".swatch-{tag} {{ background: {hex_color}; border-radius: 999px; "
                         "min-width: 24px; min-height: 24px; }")
        self._css.load_from_data("\n".join(rules).encode())

    def restyle_chrome(self):
        """Theme-coloured icons in the sidebar and header."""
        c = theme_colors()
        for i, (btn, (_label, icon)) in enumerate(zip(self.nav_buttons, self.FILTERS)):
            selected = i == self.filter_mode
            row = btn.get_child()
            slot = row.get_first_child()
            if slot.get_first_child():
                slot.remove(slot.get_first_child())
            slot.append(line_icon(icon, c["text"] if selected else c["text2"], 15))
            if selected:
                btn.add_css_class("selected")
            else:
                btn.remove_css_class("selected")

        def set_lead(box, widget):
            first = box.get_first_child()
            if first is not None and getattr(first, "_prism_icon", False):
                box.remove(first)
            widget._prism_icon = True
            box.prepend(widget)

        set_lead(self.search_icon_slot, line_icon("search", c["text3"], 13))
        set_lead(self.brain_icon_slot, line_icon("brain", c["text2"], 14))
        set_lead(self.endpoint_icon_slot, line_icon("endpoint", c["text2"], 14))
        set_lead(self.new_icon_slot, line_icon("plus", "#FFFFFF", 12, 2.2))

    # -- list

    def rebuild(self, *_):
        self.regenerate_css()
        self.restyle_chrome()
        self.status_updaters.clear()
        while (child := self.list_box.get_first_child()) is not None:
            self.list_box.remove(child)

        profiles = self.visible_profiles()
        running = [p for p in profiles if self.is_running(p)]
        idle = [p for p in profiles if not self.is_running(p)]
        self._running_set = {p.folderName for p in self.store.profiles if self.is_running(p)}
        for title, group in (("Running", running), ("Not running", idle)):
            if not group:
                continue
            head = Gtk.Box(spacing=8, margin_top=14, margin_bottom=4, margin_start=32)
            t = Gtk.Label(label=title)
            t.add_css_class("prism-section")
            n = Gtk.Label(label=str(len(group)))
            n.add_css_class("prism-dim")
            head.append(t)
            head.append(n)
            self.list_box.append(head)
            for p in group:
                self.list_box.append(self.build_row(p))

        has_any = bool(self.store.profiles)
        shown = bool(profiles)
        self.empty.set_visible(not has_any)
        self.scroller.set_visible(shown)
        self.columns.set_visible(shown)
        self.no_matches.set_visible(has_any and not shown)
        if has_any and not shown:
            self.no_matches_lbl.set_label(
                f"No profiles match “{self.search_text}”" if self.search_text
                else "Nothing is running" if self.filter_mode == 1 else "Nothing here yet")
            self.no_matches_btn.set_label("Clear search" if self.search_text else "Show all profiles")
            self.no_matches_btn.set_visible(bool(self.search_text) or self.filter_mode != 0)
        self.banner.set_visible(
            self.store.cursor_path is None and any(normalize_app(p.app) == APP_CURSOR for p in self.store.profiles))

        self.title_lbl.set_label(self.FILTERS[self.filter_mode][0])
        self.title_count.set_label(str(len(profiles)))
        for i, count in enumerate(self.nav_counts):
            count.set_label(str(sum(1 for p in self.store.profiles if self.matches(p, i))))

        names = [p.folderName for p in running + idle]
        if self.selected not in names:
            self.selected = names[0] if names else None
        self.build_inspector()
        self.refresh_status()

    def build_row(self, profile: Profile):
        tag = profile.colorHex.lstrip("#")
        app = normalize_app(profile.app)
        c = theme_colors()
        row = Gtk.Box(spacing=12, margin_start=16, margin_end=16, margin_top=1, margin_bottom=1)
        row.add_css_class("prism-row")
        if profile.folderName == self.selected:
            row.add_css_class("selected")

        name_box = Gtk.Box(spacing=10, hexpand=True)
        dot = Gtk.Box(valign=Gtk.Align.CENTER)
        dot.add_css_class(f"dot-{tag}")
        name_box.append(dot)
        name = Gtk.Label(label=profile.displayName, xalign=0, ellipsize=Pango.EllipsizeMode.END)
        name.add_css_class("prism-name")
        name_box.append(name)
        if profile.isSystem:
            t = Gtk.Label(label="Default", valign=Gtk.Align.CENTER, tooltip_text=(
                f"Your original {app_label(app)} data. Launchable and clonable, never deletable from here."))
            t.add_css_class("prism-tag")
            name_box.append(t)
        if profile.isPinned and not profile.isSystem:
            name_box.append(line_icon("pin", c["text3"], 11))
        row.append(name_box)

        app_box = Gtk.Box(spacing=7, width_request=130)
        app_box.append(line_icon(app, c["text2"], 14))
        app_lbl = Gtk.Label(label=app_label(app), xalign=0)
        app_lbl.add_css_class("prism-sub")
        app_box.append(app_lbl)
        row.append(app_box)

        status_box = Gtk.Box(spacing=7, width_request=160)
        live_dot = Gtk.Box(valign=Gtk.Align.CENTER)
        live_dot.add_css_class("prism-live")
        status = Gtk.Label(xalign=0)
        mem = Gtk.Label(xalign=0)
        mem.add_css_class("prism-dim")
        status_box.append(live_dot)
        status_box.append(status)
        status_box.append(mem)
        row.append(status_box)

        action = Gtk.Button(width_request=104, halign=Gtk.Align.END)
        action.add_css_class("prism-secondary" if profile.folderName == self.selected else "prism-quiet")
        action.connect("clicked", lambda *_, p=profile: self.launch(p))
        row.append(action)

        def update():
            running = self.is_running(profile)
            duplicating = profile.folderName in self.store.duplicating
            live = self.store.live_bytes.get(profile.folderName, 0) if running else 0
            live_dot.set_visible(running)
            if duplicating:
                status.set_label("Copying…")
            elif running:
                status.set_label("Running")
            elif profile.lastLaunchedAt:
                status.set_label(f"Idle · {format_relative(profile.lastLaunchedAt)}")
            else:
                status.set_label("Idle")
            for css, on in (("prism-running", running and not duplicating), ("prism-dim", not running)):
                (status.add_css_class if on else status.remove_css_class)(css)
            mem.set_label(format_bytes(live) if running and live else "")
            action.set_label(launch_label(profile, running))
        self.status_updaters.append(update)
        update()

        click = Gtk.GestureClick(button=1)
        click.connect("pressed", lambda g, n, x, y, p=profile: self.on_row_click(p, n))
        row.add_controller(click)
        menu_click = Gtk.GestureClick(button=3)
        menu_click.connect("pressed", lambda g, n, x, y, p=profile, r=row: self.popup_menu(p, r, x, y))
        row.add_controller(menu_click)
        if app in (APP_CURSOR, APP_CODE):
            drop = Gtk.DropTarget.new(Gio.File, Gdk.DragAction.LINK | Gdk.DragAction.COPY)
            drop.connect("drop", self.on_drop, profile)
            row.add_controller(drop)
        return row

    def on_row_click(self, profile, n_press):
        if self.selected != profile.folderName:
            self.selected = profile.folderName
            GLib.idle_add(lambda: (self.rebuild(), False)[1])
        if n_press == 2:
            self.launch(profile)

    def launch(self, profile):
        self.store.launch(profile, new_window=self.is_running(profile))

    def popup_menu(self, profile, widget, x=0, y=0):
        popover = self.build_menu(profile)
        popover.set_parent(widget)
        rect = Gdk.Rectangle()
        rect.x, rect.y, rect.width, rect.height = int(x), int(y), 1, 1
        popover.set_pointing_to(rect)
        popover.connect("closed", lambda p: GLib.idle_add(lambda: (p.unparent(), False)[1]))
        popover.popup()

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
        running = self.is_running(profile)

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

        busy = profile.folderName in self.store.duplicating
        item(launch_label(profile, running), lambda: self.launch(profile))
        item("Launch with Options…", lambda: LaunchOptionsDialog(self, self.store, profile).present())
        if running:
            item("Quit", lambda: self.store.quit_profile(profile))
        item("Unpin" if profile.isPinned else "Pin to Top", lambda: self.toggle_pin(profile))
        item("Edit…", lambda: EditorDialog(self, self.store, profile).present())
        clones_whole = normalize_app(profile.app) in (APP_CURSOR, APP_CODE)
        item("Clone into New Profile" if profile.isSystem and clones_whole
             else "Duplicate" if clones_whole else copy_menu_title(profile.app),
             lambda: self.store.duplicate(profile), enabled=not busy)
        if clones_whole:
            item(copy_menu_title(profile.app), lambda: self.store.new_overflow(profile), enabled=not busy)
        item("Open in Files", lambda: self.open_folder(profile))
        item("Update Dash Launcher" if self.store.has_launcher(profile) else "Create Dash Launcher…",
             lambda: self.store.create_or_update_launcher(profile))
        if self.store.has_launcher(profile):
            item("Remove Dash Launcher", lambda: self.store.remove_launcher(profile))
        if not profile.isSystem:
            item("Move to Trash", lambda: self.confirm_delete(profile), destructive=True)
        return popover

    def open_folder(self, profile):
        Gio.AppInfo.launch_default_for_uri(
            Gio.File.new_for_path(str(self.store.directory_for(profile))).get_uri(), None)

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

    # -- detail panel

    def update_layout(self):
        width = self.get_width() or self.get_default_size()[0]
        self.inspector.set_visible(width >= self.INSPECTOR_MIN_WIDTH and self.selected_profile() is not None)
        return False

    def build_inspector(self):
        self.inspector_updaters.clear()
        while (child := self.inspector.get_first_child()) is not None:
            self.inspector.remove(child)
        profile = self.selected_profile()
        self.update_layout()
        if profile is None:
            return
        c = theme_colors()
        app = normalize_app(profile.app)
        tag = profile.colorHex.lstrip("#")

        top = Gtk.Box(halign=Gtk.Align.END, margin_top=6, margin_bottom=6, margin_end=12)
        more = Gtk.MenuButton(icon_name="view-more-symbolic", tooltip_text="More actions")
        more.add_css_class("flat")
        more.set_popover(self.build_menu(profile))
        top.append(more)
        self.inspector.append(top)
        rule = Gtk.Box()
        rule.add_css_class("prism-rule")
        self.inspector.append(rule)

        scroller = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.inspector.append(scroller)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin_top=22, margin_bottom=20,
                          margin_start=24, margin_end=24)
        scroller.set_child(content)

        head = Gtk.Box(spacing=14)
        tile = Gtk.CenterBox(width_request=44, height_request=44, valign=Gtk.Align.START,
                             halign=Gtk.Align.START, hexpand=False)
        tile.add_css_class(f"tile-{tag}")
        tile.set_center_widget(line_icon(app, profile.colorHex, 22, 1.5))
        head.append(tile)
        names = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, valign=Gtk.Align.CENTER)
        title = Gtk.Label(label=profile.displayName, xalign=0, wrap=True)
        title.add_css_class("prism-heading")
        names.append(title)
        sub = Gtk.Label(xalign=0, label=(f"{app_label(app)} · Default profile" if profile.isSystem
                                         else app_label(app)))
        sub.add_css_class("prism-dim")
        names.append(sub)
        head.append(names)
        content.append(head)

        buttons = Gtk.Box(spacing=8, margin_top=16)
        primary = Gtk.Button(hexpand=True)
        primary.add_css_class("suggested-action")
        primary.add_css_class("prism-primary")
        primary.connect("clicked", lambda *_: self.launch(profile))
        secondary = Gtk.Button()
        secondary.add_css_class("prism-secondary")

        def on_secondary(*_):
            if self.is_running(profile):
                self.store.quit_profile(profile)
            else:
                LaunchOptionsDialog(self, self.store, profile).present()
        secondary.connect("clicked", on_secondary)
        buttons.append(primary)
        buttons.append(secondary)
        content.append(buttons)

        def divider():
            d = Gtk.Box(margin_top=20)
            d.add_css_class("prism-rule")
            content.append(d)

        def section(title_text):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin_top=16)
            t = Gtk.Label(label=title_text, xalign=0, margin_bottom=2)
            t.add_css_class("prism-section-title")
            box.append(t)
            content.append(box)
            return box

        def key_value(box, key, value=""):
            line = Gtk.Box(spacing=12)
            k = Gtk.Label(label=key, xalign=0, width_request=84, valign=Gtk.Align.START)
            k.add_css_class("prism-key")
            v = Gtk.Label(label=value, xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.MIDDLE)
            v.add_css_class("prism-value")
            line.append(k)
            line.append(v)
            box.append(line)
            return line, v

        divider()
        live_box = section("Live")
        _, status_v = key_value(live_box, "Status", "Running")
        status_v.add_css_class("prism-running")
        _, memory_v = key_value(live_box, "Memory")
        pid_line, pid_v = key_value(live_box, "Process")
        idle_box = section("Activity")
        _, idle_status = key_value(idle_box, "Status", "Idle")
        key_value(idle_box, "Last used",
                  format_relative(profile.lastLaunchedAt) if profile.lastLaunchedAt else "Never")

        divider()
        prof = section("Profile")
        directory = str(self.store.directory_for(profile))
        _, data_v = key_value(prof, "Data", "Default location" if profile.isSystem
                              else directory.replace(str(Path.home()), "~", 1))
        data_v.set_tooltip_text(directory)
        if app in (APP_CURSOR, APP_CODE):
            key_value(prof, "Project", (profile.defaultProjectPath or "None").replace(str(Path.home()), "~", 1))
        if app == APP_CURSOR:
            key_value(prof, "Memory cap", format_bytes(profile.defaultMemoryMB * 1024 * 1024))
        _, disk_v = key_value(prof, "On disk")
        key_value(prof, "Account", "Its own sign-in")

        divider()
        brain = section("Second brain")
        status = self.store.brain_status or {}
        on = bool(status.get("personalExists"))
        if app == APP_GROK:
            blurb = ("Grok agents run in the cloud. Paste the Brainium snippet into an agent's "
                     "instructions to share memory with your other apps.")
            action_label, action = "Copy snippet", self.copy_grok_snippet
        elif on:
            blurb = "Connect this profile so its agents read and write the same memory as your other apps."
            action_label, action = "Connect this profile", lambda: self.store.wire_brain(profile)
        else:
            blurb = "Set up Brainium to give every profile one shared memory."
            action_label, action = "Set up…", lambda: self.open_preferences(brain=True)
        b_lbl = Gtk.Label(label=blurb, xalign=0, wrap=True)
        b_lbl.add_css_class("prism-sub")
        brain.append(b_lbl)
        b_btn = Gtk.Button(label=action_label, halign=Gtk.Align.START)
        b_btn.add_css_class("prism-secondary")
        b_btn.connect("clicked", lambda *_: action())
        brain.append(b_btn)

        foot_rule = Gtk.Box()
        foot_rule.add_css_class("prism-rule")
        self.inspector.append(foot_rule)
        foot = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, margin_top=12, margin_bottom=12,
                       margin_start=12, margin_end=12)
        for icon_name, label, callback in (
                ("arrow", copy_action_title(profile.app), lambda: self.copy_to_new(profile)),
                ("folder", "Show data folder", lambda: self.open_folder(profile)),
                ("pin", "Update dash launcher" if self.store.has_launcher(profile) else "Create dash launcher",
                 lambda: self.store.create_or_update_launcher(profile))):
            btn = Gtk.Button()
            btn.add_css_class("prism-footer")
            line = Gtk.Box(spacing=10)
            line.append(line_icon(icon_name, c["text2"], 13))
            line.append(Gtk.Label(label=label, xalign=0))
            btn.set_child(line)
            btn.connect("clicked", lambda *_, cb=callback: cb())
            foot.append(btn)
        self.inspector.append(foot)

        def update():
            running = self.is_running(profile)
            pids = self.store.running.get(profile.folderName) or []
            live = self.store.live_bytes.get(profile.folderName, 0) if running else 0
            live_box.set_visible(running)
            idle_box.set_visible(not running)
            primary.set_label(launch_label(profile, running))
            secondary.set_label("Quit" if running else "Options…")
            cap = f" of {format_bytes(profile.defaultMemoryMB * 1024 * 1024)}" if app == APP_CURSOR else ""
            memory_v.set_label(f"{format_bytes(live)}{cap}" if live else "Measuring…")
            real = next((q for q in pids if q > 0), 0)
            pid_line.set_visible(bool(real))
            pid_v.set_label(str(real))
            idle_status.set_label(f"Idle · {format_relative(profile.lastLaunchedAt)}"
                                  if profile.lastLaunchedAt else "Idle")
            disk_v.set_label(format_bytes(self.store.sizes.get(profile.folderName)))
        self.inspector_updaters.append(update)
        update()

    def copy_to_new(self, profile):
        if normalize_app(profile.app) in (APP_CURSOR, APP_CODE):
            self.store.new_overflow(profile)
        else:
            self.store.duplicate(profile)

    def copy_grok_snippet(self):
        def done(text):
            Gdk.Display.get_default().get_clipboard().set(text)
            self.store.on_info("Grok Bot snippet copied. Paste it into the agent's instructions.")
        self.store.brain_task("Couldn't build the snippet", lambda b: b.run("snippet", "grok"), on_done=done)

    # -- live status

    def refresh_status(self, *_):
        now_running = {p.folderName for p in self.store.profiles if self.is_running(p)}
        if now_running != self._running_set:
            self.rebuild()
            return
        for update in self.status_updaters + self.inspector_updaters:
            update()
        live_total = sum(self.store.live_bytes.get(p.folderName, 0)
                         for p in self.store.profiles if self.is_running(p))
        n = len(now_running)
        self.running_lbl.set_label(f"{n} running · {format_bytes(live_total)}" if n else "Nothing running")
        cpu = f"{self.store.system_cpu:.0f}%" if self.store.system_cpu is not None else "—"
        ram = f" · {format_bytes(self.store.total_memory)} RAM" if self.store.total_memory else ""
        self.system_lbl.set_label(f"CPU {cpu}{ram}")

        status = self.store.brain_status or {}
        on = bool(status.get("personalExists"))
        self.brain_state.set_label("On" if on else "Off")
        for css, active in (("prism-live", on), ("prism-off", not on)):
            (self.brain_dot.add_css_class if active else self.brain_dot.remove_css_class)(css)
        if not self.store.brainium():
            detail = "Not set up"
        elif not on:
            detail = "No personal brain yet"
        else:
            place = f"Saving to {str(status.get('personalBrain', '')).replace(str(Path.home()), '~', 1)}"
            pending = int(status.get("pending") or 0)
            detail = f"{pending} to file · {place}" if pending else place
        self.brain_detail.set_label(detail)
        self.update_layout()


def launch_label(profile: Profile, running: bool) -> str:
    """Grok Bot has no new-window switch: launching a running profile again
    brings its window forward."""
    app = normalize_app(profile.app)
    if running:
        return "Show" if app == APP_GROK else "New Window"
    return "Open Terminal" if app == APP_CODE else "Launch"


def copy_action_title(app: str) -> str:
    return ("Copy settings to a new profile" if normalize_app(app) == APP_GROK
            else "New overflow account from this")


class EditorDialog(Adw.Window):
    """Create or edit a profile."""

    def __init__(self, parent: MainWindow, store: Store, profile: Profile | None):
        super().__init__(transient_for=parent, modal=True, default_width=460,
                         title="Edit Profile" if profile else "New Profile")
        self.parent_window = parent
        self.store = store
        self.profile = profile
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
        intro = Gtk.Label(label="Each profile keeps its own sign-in, settings and history.", xalign=0,
                          margin_top=14, margin_start=16, margin_end=16, wrap=True)
        intro.add_css_class("dim-label")
        body.append(intro)

        clamp = Adw.Clamp(margin_top=14, margin_bottom=14, margin_start=16, margin_end=16)
        body.append(clamp)
        form = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        clamp.set_child(form)

        self.name_entry = Gtk.Entry(placeholder_text="e.g. Work, Personal, Experiments",
                                    text=profile.displayName if profile else "")
        self.name_entry.connect("changed", lambda *_: self.update_preview())
        form.append(self._labeled("Name", self.name_entry))

        self.app_model = Gtk.StringList.new(
            ["Cursor (editor)", "Claude Code (CLI)", "Claude Desktop", "Grok Bot"])
        self.app_drop = Gtk.DropDown(model=self.app_model)
        current_app = normalize_app(profile.app) if profile else APP_CURSOR
        self.app_drop.set_selected(
            {APP_CURSOR: 0, APP_CODE: 1, APP_DESKTOP: 2, APP_GROK: 3}.get(current_app, 0))
        self.app_drop.set_sensitive(profile is None)  # app is fixed after creation
        self.app_drop.connect("notify::selected", lambda *_: self.on_app_changed())
        form.append(self._labeled("App", self.app_drop))

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
        self.memory_row = self._labeled("Memory limit (MB)", self.memory)
        form.append(self.memory_row)

        # Fresh account, or an overflow account carrying another same-app
        # profile's config (never its sign-in). Rebuilt when the app changes.
        self.account_sources: list[Profile] = []
        self.account_model = Gtk.StringList.new([])
        self.account_drop = Gtk.DropDown(model=self.account_model)
        self.account_drop.connect("notify::selected", lambda *_: self._update_account_hint())
        self.account_hint = Gtk.Label(xalign=0, wrap=True)
        self.account_hint.add_css_class("caption")
        self.account_hint.add_css_class("dim-label")
        self.account_row = self._labeled("Account", self.account_drop)
        self.account_row.append(self.account_hint)
        form.append(self.account_row)

        project_row = Gtk.Box(spacing=6)
        self.project = Gtk.Entry(hexpand=True, placeholder_text="Optional",
                                 text=(profile.defaultProjectPath or "") if profile else "")
        browse = Gtk.Button(label="Choose…")
        browse.connect("clicked", self.pick_folder)
        project_row.append(self.project)
        project_row.append(browse)
        self.project_row = self._labeled("Default project folder", project_row)
        form.append(self.project_row)

        # Claude Code through the Prism endpoint, with an identity's API keys.
        endpoint = Endpoint()
        self.api_choices = [None] + (["*"] + [i["id"] for i in endpoint.identities] if endpoint.identities else [])
        api_labels = ["This profile's own sign-in"] + (
            ["Endpoint: the active identity"] + [f"Endpoint: always {i.get('name', '')}" for i in endpoint.identities]
            if endpoint.identities else [])
        self.api_drop = Gtk.DropDown(model=Gtk.StringList.new(api_labels))
        current_api = profile.endpointIdentity if profile else None
        self.api_drop.set_selected(self.api_choices.index(current_api) if current_api in self.api_choices else 0)
        api_hint = Gtk.Label(xalign=0, wrap=True, label=(
            "Through the endpoint, Claude Code uses an identity's API keys instead of this profile's sign-in. "
            "Set identities up in Preferences → Endpoint."))
        api_hint.add_css_class("caption")
        api_hint.add_css_class("dim-label")
        self.api_row = self._labeled("API account", self.api_drop)
        self.api_row.append(api_hint)
        form.append(self.api_row)
        self.account_drop.connect("notify::selected", lambda *_: self._update_api_row())
        self.on_app_changed()

        if profile:
            note = Gtk.Label(xalign=0, label=(
                f"Built-in profile — {app_label(normalize_app(profile.app))} data"
                if profile.isSystem
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

    def selected_app(self):
        return {0: APP_CURSOR, 1: APP_CODE, 2: APP_DESKTOP, 3: APP_GROK}.get(
            self.app_drop.get_selected(), APP_CURSOR)

    def on_app_changed(self):
        # Memory cap only applies to Cursor; dim the field for other apps.
        app = self.selected_app()
        is_cursor = app == APP_CURSOR
        self.memory_row.set_visible(is_cursor)
        # Account choice on create; only Cursor and Claude Code open folders.
        self.account_row.set_visible(self.profile is None)
        self.project_row.set_visible(app in (APP_CURSOR, APP_CODE))
        self.account_sources = [p for p in self.store.profiles if normalize_app(p.app) == app]
        self.account_model.splice(0, self.account_model.get_n_items(),
                                  ["Fresh account — starts empty"]
                                  + [copy_source_label(p) for p in self.account_sources])
        self.account_drop.set_selected(0)
        self._update_account_hint()
        self._update_api_row()

    def _update_api_row(self):
        if hasattr(self, "api_row"):
            self.api_row.set_visible(self.selected_app() == APP_CODE
                                     and (self.profile is not None or self.account_drop.get_selected() == 0))

    @property
    def api_choice(self):
        i = self.api_drop.get_selected()
        return self.api_choices[i] if i < len(self.api_choices) else None

    def _update_account_hint(self):
        if self.account_drop.get_selected() == 0:
            text = "Starts empty — no settings, config or sign-in."
        else:
            text = OVERFLOW_EXPLAINERS[self.selected_app()]
        self.account_hint.set_label(text + " Sign in with your other account on first launch."
                                    if self.account_drop.get_selected() else text)

    def set_color(self, hex_color):
        self.color_hex = hex_color
        self.update_preview()

    def update_preview(self):
        for hex_color, btn in self.color_buttons.items():
            if hex_color == self.color_hex:
                btn.add_css_class("swatch-selected")
            else:
                btn.remove_css_class("swatch-selected")

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
            p.displayName, p.colorHex = name, self.color_hex
            p.defaultMemoryMB, p.defaultProjectPath = memory, project
            if normalize_app(p.app) == APP_CODE:
                p.endpointIdentity = self.api_choice
            self.store.update(p)
            self.close()
        elif self.account_drop.get_selected() > 0:
            source = self.account_sources[self.account_drop.get_selected() - 1]
            self.store.create_overflow(name, self.color_hex, memory,
                                       project if self.selected_app() in (APP_CURSOR, APP_CODE) else None,
                                       source)
            self.close()
        else:
            made = self.store.create(name, self.color_hex, memory, project, app=self.selected_app())
            if made:
                if self.selected_app() == APP_CODE and self.api_choice and isinstance(made, Profile):
                    made.endpointIdentity = self.api_choice
                    self.store.update(made)
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
        is_cursor = normalize_app(profile.app) == APP_CURSOR
        self.memory.set_sensitive(is_cursor)
        mem_row = EditorDialog._labeled("Memory limit (MB, Cursor only)", self.memory)
        mem_row.set_opacity(1.0 if is_cursor else 0.45)
        form.append(mem_row)

        project_row = Gtk.Box(spacing=6)
        self.project = Gtk.Entry(hexpand=True, placeholder_text="Optional",
                                 text=profile.defaultProjectPath or "")
        # Apps that never open a project folder.
        is_desktop = normalize_app(profile.app) in (APP_DESKTOP, APP_GROK)
        self.project.set_sensitive(not is_desktop)
        browse = Gtk.Button(label="Choose…")
        browse.set_sensitive(not is_desktop)
        browse.connect("clicked", self.pick_folder)
        project_row.append(self.project)
        project_row.append(browse)
        proj_row = EditorDialog._labeled("Project folder", project_row)
        proj_row.set_opacity(0.45 if is_desktop else 1.0)
        form.append(proj_row)

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

        code_group = Adw.PreferencesGroup(title="Claude Code (CLI)")
        page.add(code_group)
        code_group.add(Adw.ActionRow(title="Detected path",
                                    subtitle=store.code_path or "Not found"))
        code_custom = Adw.EntryRow(title="Custom path (empty = auto-detect)")
        code_custom.set_text(store.settings.get("customCodePath", ""))
        code_custom.connect("changed", lambda row: self._set("customCodePath", row.get_text().strip()))
        code_group.add(code_custom)

        desktop_group = Adw.PreferencesGroup(title="Claude Desktop (app)")
        page.add(desktop_group)
        desktop_group.add(Adw.ActionRow(title="Detected path",
                                       subtitle=store.desktop_path or "Not found"))
        desktop_custom = Adw.EntryRow(title="Custom path (empty = auto-detect)")
        desktop_custom.set_text(store.settings.get("customDesktopPath", ""))
        desktop_custom.connect("changed", lambda row: self._set("customDesktopPath",
                                                                row.get_text().strip()))
        desktop_group.add(desktop_custom)

        grok_group = Adw.PreferencesGroup(title="Grok Bot (app)")
        page.add(grok_group)
        grok_group.add(Adw.ActionRow(title="Detected path",
                                    subtitle=store.grok_path or "Not found"))
        grok_custom = Adw.EntryRow(title="Custom path (empty = auto-detect)")
        grok_custom.set_text(store.settings.get("customGrokPath", ""))
        grok_custom.connect("changed", lambda row: self._set("customGrokPath",
                                                            row.get_text().strip()))
        grok_group.add(grok_custom)

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

        self.brain_page = self._brain_page()
        self.add(self.brain_page)
        self.endpoint_page = EndpointPage(self)
        self.add(self.endpoint_page)
        self.connect("close-request", lambda *_: (store.refresh_brain_status(), parent.refresh_endpoint(), False)[2])

    # -- Second brain page

    def _brain_page(self):
        store = self.store
        page = Adw.PreferencesPage(title="Second brain", icon_name="system-search-symbolic")
        self.brain_page = page
        intro = Adw.PreferencesGroup(description=(
            "Brainium keeps a git-backed memory outside every account — a personal brain that "
            "follows you, plus a project brain in each repo — so agents keep their knowledge when "
            "you switch apps or accounts."))
        page.add(intro)

        where = Adw.PreferencesGroup(title="Brainium")
        page.add(where)
        cli, node = find_brainium_cli(store.settings.get("brainiumPath", "")), find_node(store.settings.get("nodePath", ""))

        def open_url(url):
            Gio.AppInfo.launch_default_for_uri(url, None)

        brain_row = Adw.ActionRow(title="Brainium",
                                  subtitle=str(Path(cli).parent.parent) if cli else "Not installed")
        if not cli:
            install = Gtk.Button(label="Install", valign=Gtk.Align.CENTER)
            install.add_css_class("suggested-action")

            def do_install(btn):
                btn.set_sensitive(False)
                btn.set_label("Installing…")
                store.install_brainium(on_done=self.close)
            install.connect("clicked", do_install)
            brain_row.add_suffix(install)
        where.add(brain_row)
        node_row = Adw.ActionRow(title="Node.js", subtitle=node or "Not installed. Brainium needs Node.js 18 or newer.")
        if not node:
            get_node = Gtk.Button(label="Get Node.js", valign=Gtk.Align.CENTER)
            get_node.connect("clicked", lambda *_: open_url(NODE_DOWNLOAD_URL))
            node_row.add_suffix(get_node)
        where.add(node_row)
        for key, title in (("brainiumPath", "Use an existing Brainium folder (empty = auto-detect)"),
                           ("nodePath", "Use a specific node binary (empty = auto-detect)")):
            row = Adw.EntryRow(title=title)
            row.set_text(store.settings.get(key, ""))
            row.connect("changed", lambda r, k=key: self._set(k, r.get_text().strip()))
            where.add(row)
        b = store.brainium()

        status = {}
        self._brain_status = status
        if b:
            try:
                status = b.status()
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
                status = {}
            self._brain_status = status

        personal = Adw.PreferencesGroup(title="Personal brain")
        page.add(personal)
        exists = bool(status.get("personalExists"))
        self.personal_row = Adw.EntryRow(title="Folder (Enter creates it)")
        self.personal_row.set_text(status.get("personalBrain", str(Path.home() / "Brainium")))
        self.personal_row.set_show_apply_button(True)
        self.personal_row.connect("apply", lambda r: store.brain_task(
            "Couldn't create the personal brain",
            lambda bb, path=r.get_text().strip(): (bb.run("init-personal", path), f"Personal brain ready at {path}.")[1]))
        personal.add(self.personal_row)
        if exists and not status.get("personalRemote"):
            personal.add(Adw.ActionRow(subtitle=(
                "Tip: push it to a private GitHub repo to use it on other machines — and so Grok Bot "
                "agents can reach it.")))

        prof = Adw.PreferencesGroup(title="Profiles")
        page.add(prof)
        auto = Adw.SwitchRow(title="Wire new profiles automatically")
        auto.set_active(bool(store.settings.get("brainAutoWire")))
        auto.connect("notify::active", lambda r, *_: self._set("brainAutoWire", r.get_active()))
        prof.add(auto)
        cap = Adw.SwitchRow(title="Capture Claude Code sessions",
                            subtitle="Redacted, private (outside git), queued to be filed into the brain")
        cap.set_active(bool(status.get("capture")))
        cap.connect("notify::active", lambda r, *_: store.set_brain_config(
            [("capture", "true" if r.get_active() else "false")]))
        prof.add(cap)
        buttons = Gtk.Box(spacing=8, margin_top=6)
        for label, handler in (("Wire All Profiles", lambda *_: store.wire_all_brains(True)),
                               ("Unwire All", lambda *_: store.wire_all_brains(False)),
                               ("Copy Grok Bot Snippet", lambda *_: self._copy_grok_snippet())):
            btn = Gtk.Button(label=label)
            btn.connect("clicked", handler)
            buttons.append(btn)
        prof.add(buttons)

        summ = Adw.PreferencesGroup(title="Summarizing captures")
        page.add(summ)
        current = (status.get("summarizer") or {}).get("provider", "agent")
        ids = [pid for pid, _ in BRAINIUM_PROVIDERS]
        self.provider_row = Adw.ComboRow(title="Summarize with",
                                         model=Gtk.StringList.new([label for _, label in BRAINIUM_PROVIDERS]))
        self.provider_row.set_selected(ids.index(current) if current in ids else 0)
        summ.add(self.provider_row)
        self.api_rows = {}
        for key, title in (("summarizer.url", "URL (required for Bonsai / OpenAI-compatible — usually ends in /v1)"),
                           ("summarizer.model", "Model (Anthropic: claude-haiku-5-5 · Bonsai: solo-quick)"),
                           ("summarizer.apiKeyEnv", "API key env var (e.g. ANTHROPIC_API_KEY)")):
            row = Adw.EntryRow(title=title)
            summ.add(row)
            self.api_rows[key] = row
        self.api_rows["summarizer.apiKey"] = Adw.PasswordEntryRow(title="API key (optional if the env var is set)")
        summ.add(self.api_rows["summarizer.apiKey"])
        save = Gtk.Button(label="Save Summarizer", halign=Gtk.Align.END, margin_top=6)
        save.connect("clicked", lambda *_: self._save_summarizer())
        summ.add(save)

        def sync_api_rows(*_):
            uses_api = ids[self.provider_row.get_selected()] not in ("agent", "none")
            for row in self.api_rows.values():
                row.set_visible(uses_api)

        self.provider_row.connect("notify::selected", sync_api_rows)
        sync_api_rows()
        return page

    def _save_summarizer(self):
        ids = [pid for pid, _ in BRAINIUM_PROVIDERS]
        provider = ids[self.provider_row.get_selected()]
        saved = (self._brain_status or {}).get("summarizer") or {}
        if (provider in ("bonsai", "openai-compatible")
                and not self.api_rows["summarizer.url"].get_text().strip()
                and not (saved.get("provider") == provider and saved.get("url"))):
            # Self-hosted servers have no default address.
            self.store.on_error("Enter your server's URL first — its OpenAI-compatible API, usually ending in /v1.")
            return
        pairs = [("summarizer.provider", provider)]
        if provider not in ("agent", "none"):
            pairs += [(k, r.get_text().strip()) for k, r in self.api_rows.items() if r.get_text().strip()]
        self.api_rows["summarizer.apiKey"].set_text("")
        self.store.set_brain_config(pairs)

    def _copy_grok_snippet(self):
        def done(text):
            Gdk.Display.get_default().get_clipboard().set(text)
            self.store.on_info("Grok Bot snippet copied — paste it into the agent's instructions.")

        self.store.brain_task("Couldn't build the snippet", lambda b: b.run("snippet", "grok"), on_done=done)

    def _set(self, key, value):
        self.store.settings[key] = value
        self.store.save_settings()


class EndpointPage(Adw.PreferencesPage):
    """Preferences → Endpoint: server, identities, automatic switching,
    setup snippets and recent requests. Refreshes every 3 s while open."""

    SNIPPETS = [("chat", "Chat apps (Open WebUI…)"), ("code", "Claude Code"), ("codex", "Codex"),
                ("desktop", "Claude Desktop")]

    def __init__(self, window: Adw.PreferencesWindow):
        super().__init__(title="Endpoint", icon_name="network-server-symbolic")
        self.window = window
        self.ep = Endpoint()
        self.status = None
        self._rows = {"identities": [], "rules": [], "log": []}
        self._alive = True

        # -- Server
        server = Adw.PreferencesGroup(
            title="Server",
            description="A local OpenAI- and Anthropic-compatible API. Point chat apps, Claude Code, Codex or "
                        "Claude Desktop at it, and every request goes out with the API keys of the identity "
                        "you pick: switch mid-chat with @work or @personal.")
        self.add(server)
        self.state_row = Adw.ActionRow(title="Status")
        self.state_button = Gtk.Button(valign=Gtk.Align.CENTER)
        self.state_button.connect("clicked", self.on_state_button)
        self.state_row.add_suffix(self.state_button)
        server.add(self.state_row)

        self.address_row = Adw.ActionRow(title="Address", subtitle_selectable=True)
        self.port_spin = Gtk.SpinButton.new_with_range(1024, 65535, 1)
        self.port_spin.set_valign(Gtk.Align.CENTER)
        self.port_spin.set_value(self.ep.port)
        self.port_spin.connect("value-changed", self.on_port)
        self.address_row.add_suffix(self.port_spin)
        self.address_row.add_suffix(self._copy_button(lambda: self.ep.base_url + "/v1"))
        server.add(self.address_row)

        self.token_row = Adw.ActionRow(title="Token", subtitle_selectable=True)
        self.token_row.add_suffix(self._copy_button(lambda: self.ep.config["token"]))
        new_token = Gtk.Button(label="New", valign=Gtk.Align.CENTER,
                               tooltip_text="Make a new main token. Apps using the old one stop working.")
        new_token.add_css_class("flat")
        new_token.connect("clicked", self.on_new_token)
        self.token_row.add_suffix(new_token)
        server.add(self.token_row)

        lan = Adw.SwitchRow(title="Allow other devices on my network",
                            subtitle="Takes effect when the endpoint restarts")
        lan.set_active(bool(self.ep.config.get("allowLAN")))
        lan.connect("notify::active", lambda r, _p: self._set("allowLAN", r.get_active()))
        server.add(lan)
        tags = Adw.SwitchRow(title="Switch with @tags in messages", subtitle="@work, @personal… (removed before sending)")
        tags.set_active(bool(self.ep.config.get("tagsEnabled", True)))
        tags.connect("notify::active", lambda r, _p: self._set("tagsEnabled", r.get_active()))
        server.add(tags)

        # -- Identities
        self.identity_group = Adw.PreferencesGroup(title="Identities")
        add_identity = Gtk.Button(label="Add identity", valign=Gtk.Align.CENTER)
        add_identity.add_css_class("flat")
        add_identity.connect("clicked", lambda *_: self.edit_identity(None))
        self.identity_group.set_header_suffix(add_identity)
        self.add(self.identity_group)

        # -- Rules
        self.rule_group = Adw.PreferencesGroup(
            title="Automatic switching",
            description="Order: a model prefix (work/…) wins, then the latest @tag in the chat, then an "
                        "identity's own token, then these rules, then the active identity.")
        add_rule = Gtk.Button(label="Add rule", valign=Gtk.Align.CENTER)
        add_rule.add_css_class("flat")
        add_rule.connect("clicked", self.on_add_rule)
        self.rule_group.set_header_suffix(add_rule)
        self.add(self.rule_group)

        # -- Connect an app
        connect = Adw.PreferencesGroup(title="Connect an app")
        self.add(connect)
        self.snippet_kind = Adw.ComboRow(title="App", model=Gtk.StringList.new([t for _, t in self.SNIPPETS]))
        self.snippet_kind.connect("notify::selected", lambda *_: self.render_snippet())
        connect.add(self.snippet_kind)
        self.snippet_token = Adw.ComboRow(
            title="Token", subtitle="The main token follows the active identity; an identity's token always uses it")
        self.snippet_token.connect("notify::selected", lambda *_: self.render_snippet())
        connect.add(self.snippet_token)
        self.snippet_view = Gtk.TextView(editable=False, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR,
                                         top_margin=10, bottom_margin=10, left_margin=12, right_margin=12)
        frame = Gtk.Frame(margin_top=10)
        frame.set_child(self.snippet_view)
        connect.add(frame)
        copy = Gtk.Button(label="Copy", halign=Gtk.Align.END, margin_top=8)
        copy.connect("clicked", lambda *_: self._copy(self._snippet_text(), "Copied"))
        connect.add(copy)

        # -- Log
        self.log_group = Adw.PreferencesGroup(title="Recent requests")
        self.add(self.log_group)

        self.render_all()
        self.refresh()
        GLib.timeout_add_seconds(3, self._tick)
        window.connect("close-request", self._on_close)

    # -- plumbing

    def _on_close(self, *_):
        self._alive = False
        return False

    def _tick(self):
        if not self._alive:
            return False
        self.refresh()
        return True

    def refresh(self):
        def done(status, _err):
            if not self._alive:
                return
            self.status = status
            self.render_state()
            self.render_identities()
            self.render_log()
        run_in_background(self.ep.status, done)

    def toast(self, text):
        self.window.add_toast(Adw.Toast(title=text, timeout=3))

    def _set(self, key, value):
        self.ep.config[key] = value
        self.ep.save()

    def _copy(self, text, message="Copied"):
        Gdk.Display.get_default().get_clipboard().set(text)
        self.toast(message)

    def _copy_button(self, value):
        btn = Gtk.Button(icon_name="edit-copy-symbolic", valign=Gtk.Align.CENTER, tooltip_text="Copy")
        btn.add_css_class("flat")
        btn.connect("clicked", lambda *_: self._copy(value()))
        return btn

    def _replace_rows(self, key, group, rows):
        for row in self._rows[key]:
            group.remove(row)
        self._rows[key] = rows
        for row in rows:
            group.add(row)

    def render_all(self):
        self.address_row.set_subtitle(self.ep.base_url + "/v1")
        self.token_row.set_subtitle(self.ep.config.get("token", ""))
        self.render_state()
        self.render_identities()
        self.render_rules()
        self.render_snippet_tokens()
        self.render_log()

    # -- server

    def render_state(self):
        if not Endpoint.find_helper():
            self.state_row.set_subtitle("The endpoint helper isn't installed")
            self.state_button.set_label("Install")
            self.state_button.add_css_class("suggested-action")
        elif self.status is not None:
            self.state_row.set_subtitle(f"Running · prism-endpoint {self.status.get('version', '')}"
                                        + (" · keys in a private file (no keyring found)"
                                           if self.status.get("keysInFile") else ""))
            self.state_button.set_label("Stop")
            self.state_button.remove_css_class("suggested-action")
        else:
            self.state_row.set_subtitle("Not running" if self.ep.config.get("enabled") else "Off")
            self.state_button.set_label("Start")
            self.state_button.add_css_class("suggested-action")

    def on_state_button(self, button):
        button.set_sensitive(False)
        label = button.get_label()

        def done(result, error):
            button.set_sensitive(True)
            if error:
                self.toast(str(error))
            elif isinstance(result, str):
                self.toast(result)
            self.refresh()

        if label == "Install":
            self.state_row.set_subtitle("Downloading the endpoint helper…")
            run_in_background(lambda: f"Installed {Endpoint.install_helper()}", done)
        elif label == "Stop":
            run_in_background(lambda: (self.ep.stop(), None)[1], done)
        else:
            self.state_row.set_subtitle("Starting…")
            run_in_background(lambda: self.ep.start() or "Running. It keeps going after Prism closes.", done)

    def on_port(self, spin):
        port = int(spin.get_value())
        if port != self.ep.port:
            self._set("port", port)
            self.address_row.set_subtitle(self.ep.base_url + "/v1")
            self.render_snippet()

    def on_new_token(self, *_):
        dialog = Adw.MessageDialog(transient_for=self.window, heading="Make a new token?",
                                   body="Apps using the current main token stop working until you give them the new one.")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("new", "New token")
        dialog.set_response_appearance("new", Adw.ResponseAppearance.DESTRUCTIVE)

        def respond(_d, response):
            if response == "new":
                self._set("token", endpoint_new_token())
                self.token_row.set_subtitle(self.ep.config["token"])
                self.render_snippet()
        dialog.connect("response", respond)
        dialog.present()

    # -- identities

    def render_identities(self):
        rows = []
        if not self.ep.identities:
            rows.append(Adw.ActionRow(title="No identities yet",
                                      subtitle="Add one for each account (Work, Personal…) with its API keys."))
        by_id = {s.get("id"): s for s in (self.status or {}).get("identities") or []}
        active = self.ep.active
        for ident in self.ep.identities:
            st = by_id.get(ident["id"])
            providers = []
            for cred in ident.get("credentials", []):
                label = endpoint_provider_label(cred.get("provider"))
                if st and cred.get("provider") != "compatible" and not (st.get("keys") or {}).get(cred.get("id")):
                    label += " (no key)"
                providers.append(label)
            subtitle = f"@{endpoint_slug(ident.get('name', ''))} · {', '.join(providers) or 'no providers'}"
            if st:
                subtitle += f"\n${st.get('monthCost', 0):.2f} this month · {st.get('monthRequests', 0)} requests"
                if st.get("budget"):
                    subtitle += f" · budget ${st['budget']:.2f}"
                if st.get("cooldownUntil"):
                    fallback = self.ep.identity(ident.get("fallbackIdentityID"))
                    subtitle += " · rate-limited" + (f": using {fallback['name']}" if fallback else "")
            row = Adw.ActionRow(title=GLib.markup_escape_text(ident.get("name", "")), subtitle=subtitle)
            dot = Gtk.Box(valign=Gtk.Align.CENTER)
            dot.add_css_class("dot-" + ident.get("colorHex", "#64748B").lstrip("#"))
            row.add_prefix(dot)
            if ident is active:
                badge = Gtk.Label(label="Active", valign=Gtk.Align.CENTER)
                badge.add_css_class("accent")
                row.add_suffix(badge)
            else:
                use = Gtk.Button(label="Use", valign=Gtk.Align.CENTER)
                use.add_css_class("flat")
                use.connect("clicked", lambda *_, i=ident: (self.ep.set_active(i["id"]), self.render_identities(),
                                                            self.render_snippet()))
                row.add_suffix(use)
            edit = Gtk.Button(label="Edit", valign=Gtk.Align.CENTER)
            edit.add_css_class("flat")
            edit.connect("clicked", lambda *_, i=ident: self.edit_identity(i))
            row.add_suffix(edit)
            rows.append(row)
        self._replace_rows("identities", self.identity_group, rows)

    def edit_identity(self, ident):
        def saved(message):
            self.ep.reload()
            self.render_all()
            self.refresh()
            if message:
                self.toast(message)
        EndpointIdentityDialog(self.window, self.ep, ident, saved).present()

    # -- rules

    def render_rules(self):
        rows = []
        if not self.ep.config["rules"]:
            rows.append(Adw.ActionRow(title="No rules",
                                      subtitle="Switch identity when a message mentions a word, a request comes "
                                               "from a particular app, or at certain times."))
        names = [i.get("name", "") for i in self.ep.identities]
        kinds = [k for k, _ in ENDPOINT_RULE_KINDS]
        for rule in self.ep.config["rules"]:
            row = Adw.ActionRow()
            # add_prefix puts each new widget first: kind, then the switch to its left.
            kind = Gtk.DropDown(model=Gtk.StringList.new([t for _, t in ENDPOINT_RULE_KINDS]), valign=Gtk.Align.CENTER)
            kind.set_selected(kinds.index(rule.get("kind")) if rule.get("kind") in kinds else 0)
            kind.connect("notify::selected", lambda d, _p, r=rule: self._rule_kind(r, kinds[d.get_selected()]))
            row.add_prefix(kind)
            on = Gtk.Switch(active=rule.get("enabled", True), valign=Gtk.Align.CENTER, tooltip_text="On")
            on.connect("notify::active", lambda s, _p, r=rule: (r.__setitem__("enabled", s.get_active()), self.ep.save()))
            row.add_prefix(on)
            entry = Gtk.Entry(hexpand=True, valign=Gtk.Align.CENTER)
            if rule.get("kind") == "schedule":
                entry.set_text(f"{_hm(rule.get('startMinute', 540))}-{_hm(rule.get('endMinute', 1020))}")
                entry.set_tooltip_text("Weekdays, from-to (24-hour), e.g. 09:00-17:00")
                entry.connect("activate", lambda e, r=rule: self._rule_schedule(r, e))
                focus = Gtk.EventControllerFocus()
                focus.connect("leave", lambda _c, e=entry, r=rule: self._rule_schedule(r, e))
            else:
                entry.set_text(rule.get("pattern", ""))
                entry.set_placeholder_text({"keyword": "words, comma separated", "regex": "regular expression"}
                                           .get(rule.get("kind"), "app name, e.g. claude-cli, codex"))
                entry.connect("changed", lambda e, r=rule: (r.__setitem__("pattern", e.get_text().strip()),
                                                            self.ep.save()))
                focus = None
            if focus:
                entry.add_controller(focus)
            row.add_suffix(entry)
            target = Gtk.DropDown(model=Gtk.StringList.new([f"→ {n}" for n in names]), valign=Gtk.Align.CENTER)
            ids = [i["id"] for i in self.ep.identities]
            if rule.get("identityID") in ids:
                target.set_selected(ids.index(rule["identityID"]))
            target.connect("notify::selected", lambda d, _p, r=rule: (
                r.__setitem__("identityID", ids[d.get_selected()]) if d.get_selected() < len(ids) else None,
                self.ep.save()))
            row.add_suffix(target)
            remove = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER, tooltip_text="Remove")
            remove.add_css_class("flat")
            remove.connect("clicked", lambda *_, r=rule: (self.ep.config["rules"].remove(r), self.ep.save(),
                                                          self.render_rules()))
            row.add_suffix(remove)
            rows.append(row)
        self._replace_rows("rules", self.rule_group, rows)

    def _rule_kind(self, rule, kind):
        if rule.get("kind") != kind:
            rule["kind"] = kind
            self.ep.save()
            GLib.idle_add(lambda: (self.render_rules(), False)[1])

    def _rule_schedule(self, rule, entry):
        parts = [p.strip() for p in entry.get_text().split("-")]
        if len(parts) == 2 and _minutes(parts[0]) is not None and _minutes(parts[1]) is not None:
            rule["startMinute"], rule["endMinute"] = _minutes(parts[0]), _minutes(parts[1])
            rule.setdefault("days", [2, 3, 4, 5, 6])
            self.ep.save()
        entry.set_text(f"{_hm(rule.get('startMinute', 540))}-{_hm(rule.get('endMinute', 1020))}")

    def on_add_rule(self, *_):
        if not self.ep.identities:
            self.toast("Add an identity first")
            return
        self.ep.config["rules"].append({
            "id": endpoint_new_id(), "enabled": True, "kind": "keyword", "pattern": "",
            "days": [2, 3, 4, 5, 6], "startMinute": 540, "endMinute": 1020,
            "identityID": self.ep.identities[0]["id"]})
        self.ep.save()
        self.render_rules()

    # -- snippets

    def render_snippet_tokens(self):
        keep = self.snippet_token.get_selected()
        self.snippet_token.set_model(Gtk.StringList.new(
            ["Main token (follows active)"] + [f"Always {i.get('name', '')}" for i in self.ep.identities]))
        self.snippet_token.set_selected(keep if 0 < keep <= len(self.ep.identities) else 0)
        self.render_snippet()

    def _snippet_text(self):
        idx = self.snippet_token.get_selected()
        token = (self.ep.identities[idx - 1]["token"] if 0 < idx <= len(self.ep.identities)
                 else self.ep.config["token"])
        kind = self.SNIPPETS[min(self.snippet_kind.get_selected(), len(self.SNIPPETS) - 1)][0]
        return self.ep.snippet(kind, token)

    def render_snippet(self):
        self.snippet_view.get_buffer().set_text(self._snippet_text())

    # -- log

    def render_log(self):
        log = (self.status or {}).get("log") or []
        rows = []
        if not log:
            rows.append(Adw.ActionRow(title="No requests yet" if self.status else
                                      "Start the endpoint to see requests here."))
        for entry in log[:30]:
            parts = [entry.get("client", ""), entry.get("reason", "")]
            if entry.get("inputTokens") or entry.get("outputTokens"):
                parts.append(f"{entry.get('inputTokens', 0):,} in / {entry.get('outputTokens', 0):,} out")
            if entry.get("cost") is not None:
                parts.append(f"${entry['cost']:.4f}")
            parts.append(f"{entry.get('ms', 0)} ms")
            parts += [entry.get("note") or "", entry.get("error") or ""]
            when = entry.get("date", "")[11:19]
            row = Adw.ActionRow(
                title=GLib.markup_escape_text(
                    f"{entry.get('identity', '')} · {entry.get('model', '')} · {entry.get('status', '')}"),
                subtitle=GLib.markup_escape_text(" · ".join(p for p in parts if p)),
                subtitle_lines=2)
            if int(entry.get("status") or 0) >= 400:
                row.add_css_class("error")
            row.add_suffix(Gtk.Label(label=_local_time(entry.get("date")) or when, css_classes=["dim-label"]))
            rows.append(row)
        self._replace_rows("log", self.log_group, rows)


def _hm(minutes) -> str:
    minutes = int(minutes)
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def _minutes(text: str):
    m = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?", text.strip())
    if not m:
        return None
    h, mins = int(m.group(1)), int(m.group(2) or 0)
    if h > 24 or mins > 59:
        return None
    return min(h * 60 + mins, 1440)


def _local_time(stamp) -> str:
    try:
        return datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).astimezone().strftime("%H:%M:%S")
    except ValueError:
        return ""


class EndpointIdentityDialog(Adw.Window):
    """Create or edit an endpoint identity: name, colour, API keys, limits, token."""

    def __init__(self, parent, ep: Endpoint, ident, on_saved):
        super().__init__(transient_for=parent, modal=True, default_width=520, default_height=700,
                         title="New identity" if ident is None else ident.get("name", "Identity"))
        self.ep = ep
        self.on_saved = on_saved
        self.is_new = ident is None
        n = len(ep.identities)
        self.ident = ident if ident is not None else {
            "id": endpoint_new_id(),
            "name": {0: "Work", 1: "Personal"}.get(n, f"Identity {n + 1}"),
            "colorHex": ENDPOINT_COLORS[n % len(ENDPOINT_COLORS)],
            "credentials": [{"id": endpoint_new_id(), "provider": "anthropic", "baseURL": ""}],
            "defaultModel": "", "token": endpoint_new_token(), "budgetAction": "fallback"}
        self.color = self.ident.get("colorHex", ENDPOINT_COLORS[0])
        self.token = self.ident.get("token") or endpoint_new_token()
        self.creds = []  # [{cred, group, provider, key, url, status}]

        toasts = Adw.ToastOverlay()
        self.toasts = toasts
        self.set_content(toasts)
        root = Adw.ToolbarView()
        toasts.set_child(root)
        header = Adw.HeaderBar(show_end_title_buttons=False, show_start_title_buttons=False)
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda *_: self.close())
        header.pack_start(cancel)
        save = Gtk.Button(label="Save")
        save.add_css_class("suggested-action")
        save.connect("clicked", self.on_save)
        header.pack_end(save)
        if not self.is_new:
            delete = Gtk.Button(label="Delete")
            delete.add_css_class("destructive-action")
            delete.connect("clicked", self.on_delete)
            header.pack_end(delete)
        root.add_top_bar(header)

        page = Adw.PreferencesPage()
        root.set_content(page)
        self.page = page

        basics = Adw.PreferencesGroup(title="Identity")
        page.add(basics)
        self.name_row = Adw.EntryRow(title="Name")
        self.name_row.set_text(self.ident.get("name", ""))
        self.name_row.connect("changed", lambda *_: self._update_slug())
        basics.add(self.name_row)
        self.slug_row = Adw.ActionRow(title="Tag")
        basics.add(self.slug_row)
        colors = Adw.ActionRow(title="Colour")
        box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        self.color_buttons = {}
        for hex_color in ENDPOINT_COLORS:
            btn = Gtk.Button(has_frame=False, width_request=22, height_request=22)
            btn.add_css_class("circular")
            btn.add_css_class("swatch-" + hex_color.lstrip("#"))
            btn.connect("clicked", lambda *_, h=hex_color: self._set_color(h))
            self.color_buttons[hex_color] = btn
            box.append(btn)
        colors.add_suffix(box)
        basics.add(colors)
        self.model_row = Adw.EntryRow(title="Default model (used for the model “prism”)")
        self.model_row.set_text(self.ident.get("defaultModel", ""))
        basics.add(self.model_row)

        self.keys_header = Adw.PreferencesGroup(
            title="API keys",
            description="Use API keys from each provider's console. Keys are kept in the system keyring, never "
                        "in the settings file. Leave a key empty to keep the saved one.")
        add = Gtk.Button(label="Add provider", valign=Gtk.Align.CENTER)
        add.add_css_class("flat")
        add.connect("clicked", self.on_add_provider)
        self.keys_header.set_header_suffix(add)
        page.add(self.keys_header)
        for cred in self.ident.get("credentials", []):
            self._add_cred(dict(cred))

        self.limits = Adw.PreferencesGroup(title="Limits")
        others = [i for i in ep.identities if i.get("id") != self.ident["id"]]
        self.fallback_ids = [None] + [i["id"] for i in others]
        self.fallback_row = Adw.ComboRow(
            title="Fall back to",
            subtitle="When rate-limited, out of credit or over budget",
            model=Gtk.StringList.new(["Nothing (show the error)"] + [i.get("name", "") for i in others]))
        fb = self.ident.get("fallbackIdentityID")
        self.fallback_row.set_selected(self.fallback_ids.index(fb) if fb in self.fallback_ids else 0)
        self.limits.add(self.fallback_row)
        self.budget_row = Adw.SpinRow.new_with_range(0, 100000, 5)
        self.budget_row.set_title("Monthly budget ($)")
        self.budget_row.set_subtitle("0 = no budget")
        self.budget_row.set_digits(2)
        self.budget_row.set_value(float(self.ident.get("monthlyBudget") or 0))
        self.limits.add(self.budget_row)
        actions = [a for a, _ in ENDPOINT_BUDGET_ACTIONS]
        self.action_row = Adw.ComboRow(title="When it's reached",
                                       model=Gtk.StringList.new([t for _, t in ENDPOINT_BUDGET_ACTIONS]))
        act = self.ident.get("budgetAction") or "fallback"
        self.action_row.set_selected(actions.index(act) if act in actions else 1)
        self.limits.add(self.action_row)
        page.add(self.limits)

        tokens = self.tokens_group = Adw.PreferencesGroup(title="Token",
                                      description="An app given this token always uses this identity, "
                                                  "whatever is active.")
        self.token_row = Adw.ActionRow(title="Identity token", subtitle=self.token, subtitle_selectable=True)
        copy = Gtk.Button(icon_name="edit-copy-symbolic", valign=Gtk.Align.CENTER, tooltip_text="Copy")
        copy.add_css_class("flat")
        copy.connect("clicked", lambda *_: (Gdk.Display.get_default().get_clipboard().set(self.token),
                                            self.toast("Token copied")))
        self.token_row.add_suffix(copy)
        renew = Gtk.Button(label="New", valign=Gtk.Align.CENTER)
        renew.add_css_class("flat")
        renew.connect("clicked", self.on_new_token)
        self.token_row.add_suffix(renew)
        tokens.add(self.token_row)
        page.add(tokens)

        self._set_color(self.color)
        self._update_slug()
        run_in_background(ep.status, self._got_status)

    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=text, timeout=3))

    def _update_slug(self):
        slug = endpoint_slug(self.name_row.get_text())
        self.slug_row.set_subtitle(f"Type @{slug} in a chat, or use the model prefix {slug}/…" if slug else "—")

    def _set_color(self, hex_color):
        self.color = hex_color
        for h, btn in self.color_buttons.items():
            (btn.add_css_class if h == hex_color else btn.remove_css_class)("swatch-selected")

    # -- credentials

    def on_add_provider(self, *_):
        used = {c["cred"]["provider"] for c in self.creds}
        nxt = next((p for p, _ in ENDPOINT_PROVIDERS if p not in used), "compatible")
        self._add_cred({"id": endpoint_new_id(), "provider": nxt, "baseURL": ""})

    def _add_cred(self, cred):
        group = Adw.PreferencesGroup()
        providers = [p for p, _ in ENDPOINT_PROVIDERS]
        provider = Adw.ComboRow(title="Provider", model=Gtk.StringList.new([t for _, t in ENDPOINT_PROVIDERS]))
        provider.set_selected(providers.index(cred.get("provider")) if cred.get("provider") in providers else 0)
        group.add(provider)
        key = Adw.PasswordEntryRow(title="API key")
        group.add(key)
        url = Adw.EntryRow(title="Base URL, e.g. http://localhost:8080/v1")
        url.set_text(cred.get("baseURL", ""))
        group.add(url)
        status = Adw.ActionRow(title="Key", subtitle="Not checked")
        check = Gtk.Button(label="Check", valign=Gtk.Align.CENTER, tooltip_text="Save and list the models this key can use")
        check.add_css_class("flat")
        status.add_suffix(check)
        remove = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER, tooltip_text="Remove")
        remove.add_css_class("flat")
        status.add_suffix(remove)
        group.add(status)
        entry = {"cred": cred, "group": group, "provider": provider, "key": key, "url": url, "status": status}

        def sync(*_):
            cred["provider"] = providers[provider.get_selected()]
            url.set_visible(cred["provider"] == "compatible")
            key.set_title("API key (if the server needs one)" if cred["provider"] == "compatible" else "API key")
        provider.connect("notify::selected", sync)
        sync()
        check.connect("clicked", lambda *_: self.on_check(entry))
        remove.connect("clicked", lambda *_: (self.creds.remove(entry), self.page.remove(group)))

        # Keep credential groups together, right after the "API keys" header.
        self.page.add(group)
        self.creds.append(entry)
        if hasattr(self, "limits"):
            # Re-append later groups so new providers sit above Limits/Token.
            for later in self._tail_groups():
                self.page.remove(later)
                self.page.add(later)

    def _tail_groups(self):
        return [g for g in (getattr(self, "limits", None), getattr(self, "tokens_group", None)) if g is not None]

    def _got_status(self, status, _err):
        st = next((s for s in (status or {}).get("identities") or [] if s.get("id") == self.ident["id"]), None)
        if not st:
            return
        for c in self.creds:
            if c["cred"].get("provider") == "compatible":
                continue
            has = (st.get("keys") or {}).get(c["cred"]["id"])
            c["status"].set_subtitle("Saved" if has else "No key saved yet")

    def on_check(self, entry):
        entry["status"].set_subtitle("Checking…")
        snap = self._capture()

        def work():
            err = self._commit(snap)
            if err:
                return err
            if self.ep.status() is None:
                return "Saved. Start the endpoint to check the key."
            error, models = self.ep.check(entry["cred"]["id"])
            if error:
                return error
            shown = ", ".join(models[:4]) + ("…" if len(models) > 4 else "")
            return f"Works · {len(models)} models: {shown}" if models else "Works"

        run_in_background(work, lambda result, error: entry["status"].set_subtitle(
            GLib.markup_escape_text(str(error or result))))

    # -- save

    def _capture(self):
        return {
            "name": self.name_row.get_text().strip(),
            "model": self.model_row.get_text().strip(),
            "fallback": self.fallback_ids[self.fallback_row.get_selected()]
            if self.fallback_row.get_selected() < len(self.fallback_ids) else None,
            "budget": self.budget_row.get_value(),
            "action": ENDPOINT_BUDGET_ACTIONS[self.action_row.get_selected()][0],
            "creds": [(c["cred"], c["url"].get_text().strip(), c["key"].get_text().strip()) for c in self.creds],
        }

    def _commit(self, snap):
        """Write the edits to the settings and keyring; returns an error or None.
        Runs on a worker thread (saving a key may call the helper), so it only
        uses values captured from the widgets beforehand."""
        name = snap["name"]
        if not name:
            return "Give the identity a name."
        slug = endpoint_slug(name)
        if any(i.get("id") != self.ident["id"] and endpoint_slug(i.get("name", "")) == slug
               for i in self.ep.identities):
            return f"Another identity is already called @{slug}."
        for cred, url, _key in snap["creds"]:
            cred["baseURL"] = url
            if cred["provider"] == "compatible" and not url:
                return "An OpenAI-compatible provider needs a base URL."
        ident = self.ident
        ident.update({"name": name, "colorHex": self.color, "defaultModel": snap["model"], "token": self.token,
                      "budgetAction": snap["action"], "credentials": [c for c, _u, _k in snap["creds"]]})
        for key, value in (("fallbackIdentityID", snap["fallback"]),
                           ("monthlyBudget", snap["budget"] if snap["budget"] > 0 else None)):
            if value is None:
                ident.pop(key, None)
            else:
                ident[key] = value
        if self.is_new:
            self.ep.identities.append(ident)
            self.ep.config.setdefault("activeIdentityID", ident["id"])
            self.is_new = False
        self.ep.save()
        for cred, _url, key in snap["creds"]:
            if key:
                err = self.ep.set_key(cred["id"], key)
                if err:
                    return f"{endpoint_provider_label(cred['provider'])} key: {err}"
        return None

    def on_save(self, button):
        snap = self._capture()
        button.set_sensitive(False)
        name = snap["name"]

        def done(err, exc):
            button.set_sensitive(True)
            if exc or err:
                self.toast(str(exc or err))
                return
            self.on_saved(f"Saved {name}")
            self.close()
        run_in_background(lambda: self._commit(snap), done)

    def on_new_token(self, *_):
        self.token = endpoint_new_token()
        self.token_row.set_subtitle(self.token)
        self.toast("New token: Save to use it")

    def on_delete(self, *_):
        dialog = Adw.MessageDialog(transient_for=self, heading=f"Delete {self.ident.get('name', '')}?",
                                   body="Apps using its token stop working. Its saved keys stay in the keyring.")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("delete", "Delete")
        dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE)

        def respond(_d, response):
            if response != "delete":
                return
            cfg, gone = self.ep.config, self.ident["id"]
            cfg["identities"] = [i for i in cfg["identities"] if i.get("id") != gone]
            cfg["rules"] = [r for r in cfg["rules"] if r.get("identityID") != gone]
            for i in cfg["identities"]:
                if i.get("fallbackIdentityID") == gone:
                    i.pop("fallbackIdentityID", None)
            if cfg.get("activeIdentityID") == gone:
                cfg["activeIdentityID"] = cfg["identities"][0]["id"] if cfg["identities"] else None
                if cfg["activeIdentityID"] is None:
                    cfg.pop("activeIdentityID")
            self.ep.save()
            self.on_saved(f"Deleted {self.ident.get('name', '')}")
            self.close()
        dialog.connect("response", respond)
        dialog.present()


class CursorProfilesApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)
        self.store = None

    def do_activate(self):
        # Follow the system light/dark setting (the palette has both).
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.DEFAULT)
        window = self.get_active_window()
        if not window:
            if self.store is None:
                self.store = Store()
            window = MainWindow(self, self.store)
        window.present()


if __name__ == "__main__":
    app = CursorProfilesApp()
    raise SystemExit(app.run(None))
