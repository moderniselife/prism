package main

// Profile storage, Cursor discovery, launch/quit and process detection.
// Mirrors the macOS/Windows/Linux apps: same ~/.cursor_profiles layout and
// the same .profiles.json schema (Apple-epoch timestamps for portability).

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

// Seconds between 2001-01-01 (Apple epoch, what the Swift app writes) and
// 1970-01-01 (Unix epoch).
const appleEpochOffset = 978307200.0

const metadataName = ".profiles.json"
const settingsName = ".launcher-settings.json"

// systemFolderName marks the built-in Cursor profile. Never a real folder.
const systemFolderName = "__cursor-default__"

// systemCodeFolderName marks the built-in Claude Code profile (the real
// ~/.claude config). Never a real folder inside the Code profiles dir.
const systemCodeFolderName = "__claude-code-default__"

// systemDesktopFolderName marks the built-in Claude Desktop profile (the
// real Electron userData dir). Never a real folder in the Desktop dir.
const systemDesktopFolderName = "__claude-desktop-default__"

// App identifiers. Stored in .profiles.json as "app"; absent means cursor
// (all files written before multi-app support).
const (
	AppCursor        = "cursor"
	AppClaudeCode    = "claude-code"
	AppClaudeDesktop = "claude-desktop"
)

type Profile struct {
	FolderName         string     `json:"folderName"`
	DisplayName        string     `json:"displayName"`
	App                string     `json:"app"`
	ColorHex           string     `json:"colorHex"`
	DefaultMemoryMB    int        `json:"defaultMemoryMB"`
	DefaultProjectPath *string    `json:"defaultProjectPath"`
	CreatedAt          time.Time  `json:"-"`
	LastLaunchedAt     *time.Time `json:"-"`
	IsPinned           bool       `json:"isPinned"`
	IsSystem           bool       `json:"isSystem"`
}

// NOTE: older .profiles.json files may carry an "emoji" key. It has no field
// here and encoding/json skips unknown keys, so old files load and new
// files omit it.
type profileJSON struct {
	FolderName         string   `json:"folderName"`
	DisplayName        string   `json:"displayName"`
	App                string   `json:"app"`
	ColorHex           string   `json:"colorHex"`
	DefaultMemoryMB    int      `json:"defaultMemoryMB"`
	DefaultProjectPath *string  `json:"defaultProjectPath"`
	CreatedAt          *float64 `json:"createdAt"`
	LastLaunchedAt     *float64 `json:"lastLaunchedAt"`
	IsPinned           bool     `json:"isPinned"`
	IsSystem           bool     `json:"isSystem"`
}

func appleToTime(sec float64) time.Time {
	return time.Unix(int64(sec+appleEpochOffset), 0).UTC()
}

func timeToApple(t time.Time) float64 {
	return float64(t.Unix()) - appleEpochOffset
}

func (p Profile) toJSON() profileJSON {
	j := profileJSON{
		FolderName:         p.FolderName,
		DisplayName:        p.DisplayName,
		App:                p.App,
		ColorHex:           p.ColorHex,
		DefaultMemoryMB:    p.DefaultMemoryMB,
		DefaultProjectPath: p.DefaultProjectPath,
		IsPinned:           p.IsPinned,
		IsSystem:           p.IsSystem,
	}
	if j.App == "" {
		j.App = AppCursor
	}
	created := timeToApple(p.CreatedAt)
	j.CreatedAt = &created
	if p.LastLaunchedAt != nil {
		last := timeToApple(*p.LastLaunchedAt)
		j.LastLaunchedAt = &last
	}
	return j
}

func profileFromJSON(j profileJSON) Profile {
	p := Profile{
		FolderName:         j.FolderName,
		DisplayName:        j.DisplayName,
		App:                j.App,
		ColorHex:           j.ColorHex,
		DefaultMemoryMB:    j.DefaultMemoryMB,
		DefaultProjectPath: j.DefaultProjectPath,
		IsPinned:           j.IsPinned,
		IsSystem:           j.IsSystem,
	}
	if p.App != AppClaudeCode && p.App != AppClaudeDesktop {
		// Absent or unknown: files predating multi-app support are Cursor.
		p.App = AppCursor
	}
	if j.CreatedAt != nil {
		p.CreatedAt = appleToTime(*j.CreatedAt)
	} else {
		p.CreatedAt = time.Now().UTC()
	}
	if j.LastLaunchedAt != nil {
		t := appleToTime(*j.LastLaunchedAt)
		p.LastLaunchedAt = &t
	}
	if p.ColorHex == "" {
		p.ColorHex = "#6366F1"
	}
	if p.DefaultMemoryMB < 512 {
		p.DefaultMemoryMB = 16384
	}
	return p
}

// Initial is the tile glyph: first letter of the display name, uppercased.
func (p Profile) Initial() string {
	name := strings.TrimSpace(p.DisplayName)
	if name == "" {
		return "?"
	}
	return strings.ToUpper(string([]rune(name)[0]))
}

func (p Profile) LimitBytes() uint64 {
	if p.App != AppCursor {
		// Only Cursor launches with --max-memory; Claude apps have no
		// per-profile memory cap, so there is no limit to report.
		return 0
	}
	if p.DefaultMemoryMB < 0 {
		return 0
	}
	return uint64(p.DefaultMemoryMB) * 1024 * 1024
}

// AppLabel is the short human tag shown in list rows and filters.
func (p Profile) AppLabel() string {
	switch p.App {
	case AppClaudeCode:
		return "Code"
	case AppClaudeDesktop:
		return "Desktop"
	default:
		return "Cursor"
	}
}

// systemMarkerFor returns the reserved folder name for an app's built-in
// profile, or "" when the app has none.
func systemMarkerFor(app string) string {
	switch app {
	case AppClaudeCode:
		return systemCodeFolderName
	case AppClaudeDesktop:
		return systemDesktopFolderName
	default:
		return systemFolderName
	}
}

type Store struct {
	Dir              string // Cursor profiles (historical default)
	CodeDir          string // Claude Code profiles (CLAUDE_CONFIG_DIR values)
	DesktopDir       string // Claude Desktop profiles (Electron user-data-dirs)
	Profiles         []Profile
	defaultMemoryMB  int
	customCursorPath string
	customCodePath   string
	customDesktopPath string
}

func defaultDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".cursor_profiles"
	}
	return filepath.Join(home, ".cursor_profiles")
}

func defaultCodeDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".claude_code_profiles"
	}
	return filepath.Join(home, ".claude_code_profiles")
}

func defaultDesktopDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".claude_desktop_profiles"
	}
	return filepath.Join(home, ".claude_desktop_profiles")
}

// dirForApp returns the profiles root for an app identifier.
func (s *Store) dirForApp(app string) string {
	switch app {
	case AppClaudeCode:
		return s.CodeDir
	case AppClaudeDesktop:
		return s.DesktopDir
	default:
		return s.Dir
	}
}

func systemDataDir() string {
	return systemDataDirFor(AppCursor)
}

// systemDataDirFor is the real (built-in) data location per app:
// Cursor and Claude Desktop keep Electron-style user data; Claude Code
// keeps its config in ~/.claude (overridable via CLAUDE_CONFIG_DIR, which
// is exactly what per-profile isolation uses).
func systemDataDirFor(app string) string {
	home, _ := os.UserHomeDir()
	switch app {
	case AppClaudeCode:
		if custom := os.Getenv("CLAUDE_CONFIG_DIR"); custom != "" {
			return custom
		}
		return filepath.Join(home, ".claude")
	case AppClaudeDesktop:
		switch runtime.GOOS {
		case "darwin":
			return filepath.Join(home, "Library", "Application Support", "Claude")
		case "windows":
			// Microsoft Store install (verified on this machine):
			// %LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude
			if local := os.Getenv("LOCALAPPDATA"); local != "" {
				store := filepath.Join(local, "Packages", "Claude_pzs8sxrjxfjjc",
					"LocalCache", "Roaming", "Claude")
				if st, err := os.Stat(store); err == nil && st.IsDir() {
					return store
				}
			}
			if appdata := os.Getenv("APPDATA"); appdata != "" {
				return filepath.Join(appdata, "Claude")
			}
			return filepath.Join(home, "AppData", "Roaming", "Claude")
		default:
			if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
				return filepath.Join(xdg, "Claude")
			}
			return filepath.Join(home, ".config", "Claude")
		}
	default:
		// Cursor
		switch runtime.GOOS {
		case "darwin":
			return filepath.Join(home, "Library", "Application Support", "Cursor")
		case "windows":
			if appdata := os.Getenv("APPDATA"); appdata != "" {
				return filepath.Join(appdata, "Cursor")
			}
			return filepath.Join(home, "AppData", "Roaming", "Cursor")
		default:
			if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
				return filepath.Join(xdg, "Cursor")
			}
			return filepath.Join(home, ".config", "Cursor")
		}
	}
}

func sanitizeFolderName(raw string) string {
	var b strings.Builder
	for _, r := range raw {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			b.WriteRune(r)
		} else if r > 127 {
			// Drop non-ASCII (letters with diacritics included): folder names
			// stay portable across the three apps.
		}
	}
	return b.String()
}

func LoadStore() (*Store, error) {
	s := &Store{Dir: defaultDir(), CodeDir: defaultCodeDir(), DesktopDir: defaultDesktopDir(), defaultMemoryMB: 16384}
	if err := os.MkdirAll(s.Dir, 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(s.CodeDir, 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(s.DesktopDir, 0o755); err != nil {
		return nil, err
	}
	s.loadSettings()
	if err := s.reload(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) loadSettings() {
	// Written by the Linux/Windows apps; harmless if absent.
	data, err := os.ReadFile(filepath.Join(s.Dir, settingsName))
	if err != nil {
		return
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return
	}
	if v, ok := raw["customCursorPath"].(string); ok {
		s.customCursorPath = v
	}
	if v, ok := raw["customCodePath"].(string); ok {
		s.customCodePath = v
	}
	if v, ok := raw["customDesktopPath"].(string); ok {
		s.customDesktopPath = v
	}
	if v, ok := raw["defaultMemoryMB"].(float64); ok && v >= 512 {
		s.defaultMemoryMB = int(v)
	}
}

func (s *Store) metadataPath() string {
	return filepath.Join(s.Dir, metadataName)
}

func (s *Store) metadataPathFor(app string) string {
	return filepath.Join(s.dirForApp(app), metadataName)
}

func (s *Store) dirFor(p Profile) string {
	if p.IsSystem {
		return systemDataDirFor(p.App)
	}
	return filepath.Join(s.dirForApp(p.App), p.FolderName)
}

func (s *Store) reload() error {
	var all []Profile
	for _, app := range []string{AppCursor, AppClaudeCode, AppClaudeDesktop} {
		profiles, err := s.reloadApp(app)
		if err != nil {
			return err
		}
		all = append(all, profiles...)
	}
	s.Profiles = all
	return s.save()
}

// reloadApp loads one app's profiles: its own metadata file plus any
// hand-created directories, its own built-in profile, then persists.
func (s *Store) reloadApp(app string) ([]Profile, error) {
	dir := s.dirForApp(app)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	var known []profileJSON
	if data, err := os.ReadFile(filepath.Join(dir, metadataName)); err == nil {
		_ = json.Unmarshal(data, &known) // corrupt file: rebuild from disk
	}
	profiles := make([]Profile, 0, len(known))
	for _, j := range known {
		if j.FolderName == "" {
			continue
		}
		p := profileFromJSON(j)
		if p.App != app {
			// A folder shared by another app's file (e.g. a copied
			// .profiles.json): keep it with its own app instead.
			p.App = app
			if p.IsSystem {
				continue
			}
		}
		profiles = append(profiles, p)
	}

	entries, _ := os.ReadDir(dir)
	onDisk := map[string]bool{}
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		onDisk[e.Name()] = true
	}
	for name := range onDisk {
		found := false
		for _, p := range profiles {
			if p.FolderName == name {
				found = true
				break
			}
		}
		if !found {
			display := strings.TrimPrefix(name, "custom_")
			profiles = append(profiles, Profile{
				FolderName:      name,
				DisplayName:     display,
				App:             app,
				ColorHex:        accentFor(name),
				DefaultMemoryMB: s.defaultMemoryMB,
				CreatedAt:       time.Now().UTC(),
			})
		}
	}
	kept := profiles[:0]
	for _, p := range profiles {
		if p.IsSystem || onDisk[p.FolderName] {
			kept = append(kept, p)
		}
	}
	profiles = kept

	hasSystem := false
	for _, p := range profiles {
		if p.IsSystem {
			hasSystem = true
			break
		}
	}
	if !hasSystem {
		if st, err := os.Stat(systemDataDirFor(app)); err == nil && st.IsDir() {
			profiles = append([]Profile{{
				FolderName:      systemMarkerFor(app),
				DisplayName:     systemDisplayName(app),
				App:             app,
				ColorHex:        "#3B82F6",
				DefaultMemoryMB: 16384,
				CreatedAt:       time.Now().UTC(),
				IsPinned:        true,
				IsSystem:        true,
			}}, profiles...)
		}
	}

	return profiles, s.saveApp(app, profiles)
}

// systemDisplayName is the built-in card title per app.
func systemDisplayName(app string) string {
	switch app {
	case AppClaudeCode:
		return "Main Claude Code"
	case AppClaudeDesktop:
		return "Main Claude Desktop"
	default:
		return "Main Cursor"
	}
}

func (s *Store) save() error {
	byApp := map[string][]Profile{
		AppCursor:        {},
		AppClaudeCode:    {},
		AppClaudeDesktop: {},
	}
	for _, p := range s.Profiles {
		app := p.App
		if app != AppClaudeCode && app != AppClaudeDesktop {
			app = AppCursor
		}
		byApp[app] = append(byApp[app], p)
	}
	for app, profiles := range byApp {
		if err := s.saveApp(app, profiles); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) saveApp(app string, profiles []Profile) error {
	out := make([]profileJSON, 0, len(profiles))
	for _, p := range profiles {
		out = append(out, p.toJSON())
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(s.dirForApp(app), metadataName), append(data, '\n'), 0o644)
}

var palette = []string{
	"#6366F1", "#8B5CF6", "#D946EF", "#F43F5E", "#F97316", "#F59E0B",
	"#10B981", "#14B8A6", "#0EA5E9", "#3B82F6", "#64748B", "#84CC16",
}

func accentFor(name string) string {
	h := 0
	for _, r := range name {
		h = h*31 + int(r)
	}
	if h < 0 {
		h = -h
	}
	return palette[h%len(palette)]
}

func (s *Store) uniqueFolderName(base string) string {
	existing := map[string]bool{}
	for _, p := range s.Profiles {
		existing[strings.ToLower(p.FolderName)] = true
	}
	// Folder names stay globally unique across apps: the live-stats maps
	// in every client are keyed by folder name.
	folder, counter := base, 2
	lower := strings.ToLower(folder)
	for lower == systemFolderName || lower == systemCodeFolderName ||
		lower == systemDesktopFolderName || existing[lower] {
		folder = fmt.Sprintf("%s-%d", base, counter)
		counter++
		lower = strings.ToLower(folder)
	}
	return folder
}

func (s *Store) Create(displayName, colorHex string, memoryMB int, projectPath string) (*Profile, error) {
	return s.CreateApp(displayName, AppCursor, colorHex, memoryMB, projectPath)
}

func (s *Store) CreateApp(displayName, app, colorHex string, memoryMB int, projectPath string) (*Profile, error) {
	if app != AppClaudeCode && app != AppClaudeDesktop {
		app = AppCursor
	}
	base := sanitizeFolderName(strings.ReplaceAll(displayName, " ", "_"))
	if base == "" {
		return nil, errors.New("profile name must contain at least one letter, number, hyphen or underscore")
	}
	if memoryMB < 512 {
		memoryMB = 16384
	}
	if colorHex == "" {
		colorHex = accentFor(base)
	}
	p := Profile{
		FolderName:      s.uniqueFolderName(base),
		DisplayName:     strings.TrimSpace(displayName),
		App:             app,
		ColorHex:        colorHex,
		DefaultMemoryMB: memoryMB,
		CreatedAt:       time.Now().UTC(),
	}
	if strings.TrimSpace(projectPath) != "" {
		pp := strings.TrimSpace(projectPath)
		p.DefaultProjectPath = &pp
	}
	if err := os.MkdirAll(s.dirFor(p), 0o755); err != nil {
		return nil, fmt.Errorf("could not create profile folder: %w", err)
	}
	if app == AppCursor {
		_ = applyTitleBarColor(s.dirFor(p), p.ColorHex)
	}
	// Claude Desktop: seed a fresh profile with the user's MCP/connectors
	// config so a new profile starts useful, without copying GBs of cache.
	if app == AppClaudeDesktop && !p.IsSystem {
		seedDesktopConfig(systemDataDirFor(app), s.dirFor(p))
	}
	s.Profiles = append(s.Profiles, p)
	if err := s.save(); err != nil {
		return nil, err
	}
	return &s.Profiles[len(s.Profiles)-1], nil
}

// seedDesktopConfig copies just claude_desktop_config.json (MCP servers,
// connectors) from the main install into a fresh profile dir.
func seedDesktopConfig(systemDir, profileDir string) {
	src, err := os.ReadFile(filepath.Join(systemDir, "claude_desktop_config.json"))
	if err != nil {
		return
	}
	dst := filepath.Join(profileDir, "claude_desktop_config.json")
	if _, err := os.Stat(dst); err == nil {
		return // don't overwrite an adopted profile's own config
	}
	_ = os.WriteFile(dst, src, 0o644)
}

// Delete moves the profile folder to a timestamped trash directory inside
// its own app dir's .trash (hidden, so it is never re-adopted as a
// profile). Recoverable, unlike rm -rf.
func (s *Store) Delete(p Profile) error {
	if p.IsSystem {
		return errors.New("the built-in profile can't be deleted — it's your original app data")
	}
	dir := s.dirFor(p)
	trash := filepath.Join(s.dirForApp(p.App), ".trash")
	if err := os.MkdirAll(trash, 0o755); err != nil {
		return err
	}
	dest := filepath.Join(trash, fmt.Sprintf("%s-%d", p.FolderName, time.Now().Unix()))
	if err := os.Rename(dir, dest); err != nil {
		return fmt.Errorf("could not move profile to trash: %w", err)
	}
	kept := s.Profiles[:0]
	for _, q := range s.Profiles {
		if q.FolderName != p.FolderName {
			kept = append(kept, q)
		}
	}
	s.Profiles = kept
	return s.save()
}

// Launch starts the right app for the profile. Pass newWindow for a running
// profile — without it the app just refocuses and the click looks dead.
// Claude Code profiles launch the `claude` CLI with CLAUDE_CONFIG_DIR set
// (the documented multi-account mechanism); Claude Desktop and Cursor
// launch with --user-data-dir isolation.
func (s *Store) Launch(p Profile, newWindow bool) error {
	var err error
	switch p.App {
	case AppClaudeCode:
		err = s.launchCode(p)
	case AppClaudeDesktop:
		err = s.launchDesktop(p, newWindow)
	default:
		err = s.launchCursor(p, newWindow)
	}
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	for i := range s.Profiles {
		if s.Profiles[i].FolderName == p.FolderName {
			s.Profiles[i].LastLaunchedAt = &now
			break
		}
	}
	return s.save()
}

func (s *Store) launchCursor(p Profile, newWindow bool) error {
	exe, err := findCursor(s.customCursorPath)
	if err != nil {
		return err
	}
	args := []string{fmt.Sprintf("--max-memory=%d", p.DefaultMemoryMB)}
	if !p.IsSystem {
		dir := s.dirFor(p)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		args = append([]string{"--user-data-dir", dir}, args...)
		_ = applyTitleBarColor(dir, p.ColorHex) // idempotent
	}
	if newWindow {
		args = append(args, "--new-window")
	}
	if p.DefaultProjectPath != nil && *p.DefaultProjectPath != "" {
		args = append(args, *p.DefaultProjectPath)
	}
	cmd := exec.Command(exe, args...)
	cmd.Stdout, cmd.Stderr = nil, nil
	cmd.SysProcAttr = detachAttr()
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to launch Cursor: %w", err)
	}
	return nil
}

// launchCode prepares a Claude Code profile. The CLI is interactive and
// needs the user's own terminal, so Prism never starts it headless here:
// GUI clients open a terminal with CLAUDE_CONFIG_DIR set (see CodeCommand),
// while the TUI prints the command for the user to run.
func (s *Store) launchCode(p Profile) error {
	if _, err := findClaudeCode(s.customCodePath); err != nil {
		return err
	}
	dir := s.dirFor(p)
	if !p.IsSystem {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	return nil
}

// CodeCommand returns the shell command that opens this profile's account:
// portable across sh, bash, zsh and PowerShell callers copy-paste it.
func (s *Store) CodeCommand(p Profile) string {
	return fmt.Sprintf("CLAUDE_CONFIG_DIR=%q claude", s.dirFor(p))
}

// launchDesktop starts Claude Desktop. Managed profiles pass the Chromium
// --user-data-dir=<dir> switch (it must use "=": Chromium doesn't take a
// space-separated value). On Windows only the standalone-installer build
// honors it; the Store build drops launch flags, so it's refused with an
// install hint.
func (s *Store) launchDesktop(p Profile, newWindow bool) error {
	exe, err := findClaudeDesktop(s.customDesktopPath)
	if err != nil {
		return err
	}
	var args []string
	if !p.IsSystem {
		if runtime.GOOS == "windows" {
			classic, cerr := findClassicDesktop(s.customDesktopPath)
			if cerr != nil {
				return cerr
			}
			exe = classic
		}
		dir := s.dirFor(p)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		args = append(args, "--user-data-dir="+dir)
	}
	if newWindow {
		args = append(args, "--new-window")
	}
	cmd := exec.Command(exe, args...)
	cmd.Stdout, cmd.Stderr = nil, nil
	cmd.SysProcAttr = detachAttr()
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to launch Claude Desktop: %w", err)
	}
	return nil
}

func findCursor(custom string) (string, error) {
	if custom != "" {
		if st, err := os.Stat(custom); err == nil && !st.IsDir() {
			return custom, nil
		}
	}
	home, _ := os.UserHomeDir()
	var candidates []string
	switch runtime.GOOS {
	case "darwin":
		candidates = []string{
			"/Applications/Cursor.app/Contents/MacOS/Cursor",
			filepath.Join(home, "Applications", "Cursor.app", "Contents", "MacOS", "Cursor"),
			"/usr/local/bin/cursor",
			"/opt/homebrew/bin/cursor",
		}
	case "windows":
		local, programs := os.Getenv("LOCALAPPDATA"), os.Getenv("ProgramFiles")
		candidates = []string{
			filepath.Join(local, "Programs", "cursor", "Cursor.exe"),
			filepath.Join(local, "Programs", "Cursor", "Cursor.exe"),
			filepath.Join(programs, "Cursor", "Cursor.exe"),
		}
	default:
		candidates = []string{
			"/usr/bin/cursor", "/usr/local/bin/cursor", "/opt/cursor/cursor",
			filepath.Join(home, ".local", "bin", "cursor"),
		}
		if matches, _ := filepath.Glob(filepath.Join(home, "Applications", "Cursor*.AppImage")); len(matches) > 0 {
			candidates = append(candidates, matches...)
		}
	}
	if pathEnv := os.Getenv("PATH"); pathEnv != "" {
		for _, dir := range strings.Split(pathEnv, string(os.PathListSeparator)) {
			name := "Cursor.exe"
			if runtime.GOOS != "windows" {
				name = "cursor"
			}
			candidates = append(candidates, filepath.Join(dir, name))
		}
	}
	for _, c := range candidates {
		if c == "" {
			continue
		}
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c, nil
		}
	}
	return "", errors.New("Cursor could not be found. Install it from cursor.sh or set a custom path")
}

// findClaudeCode locates the Claude Code CLI: custom path -> PATH.
func findClaudeCode(custom string) (string, error) {
	if custom != "" {
		if st, err := os.Stat(custom); err == nil && !st.IsDir() {
			return custom, nil
		}
	}
	names := []string{"claude"}
	if runtime.GOOS == "windows" {
		names = []string{"claude.exe", "claude.cmd", "claude"}
	}
	for _, name := range names {
		if path, err := exec.LookPath(name); err == nil {
			return path, nil
		}
	}
	home, _ := os.UserHomeDir()
	var fallbacks []string
	switch runtime.GOOS {
	case "darwin":
		fallbacks = []string{
			"/usr/local/bin/claude",
			"/opt/homebrew/bin/claude",
			filepath.Join(home, ".local", "bin", "claude"),
		}
	case "windows":
		if local := os.Getenv("LOCALAPPDATA"); local != "" {
			fallbacks = []string{
				filepath.Join(local, "Programs", "Claude", "claude.exe"),
			}
		}
	default:
		fallbacks = []string{
			"/usr/bin/claude",
			"/usr/local/bin/claude",
			filepath.Join(home, ".local", "bin", "claude"),
		}
	}
	for _, c := range fallbacks {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c, nil
		}
	}
	return "", errors.New("Claude Code could not be found. Install it (see code.claude.com/docs) or set a custom path")
}

// findClaudeDesktop locates the Claude Desktop app: custom path ->
// well-known installs -> PATH.
func findClaudeDesktop(custom string) (string, error) {
	if custom != "" {
		if st, err := os.Stat(custom); err == nil && !st.IsDir() {
			return custom, nil
		}
	}
	home, _ := os.UserHomeDir()
	var candidates []string
	switch runtime.GOOS {
	case "darwin":
		candidates = []string{
			"/Applications/Claude.app/Contents/MacOS/Claude",
			filepath.Join(home, "Applications", "Claude.app", "Contents", "MacOS", "Claude"),
		}
	case "windows":
		local := os.Getenv("LOCALAPPDATA")
		programs := os.Getenv("ProgramFiles")
		candidates = []string{
			// Classic installer locations FIRST: only real executables
			// honor --user-data-dir. The Store alias is a last resort
			// (it opens the main app fine, but Windows drops its flags).
			filepath.Join(local, "Programs", "Claude", "Claude.exe"),
			filepath.Join(local, "AnthropicClaude", "Claude.exe"),
			filepath.Join(programs, "Claude", "Claude.exe"),
			// Microsoft Store app execution alias (0-byte shim).
			filepath.Join(local, "Microsoft", "WindowsApps", "claude-desktop.exe"),
		}
	default:
		candidates = []string{
			"/usr/bin/claude-desktop",
			"/usr/local/bin/claude-desktop",
			"/opt/Claude/claude-desktop",
			filepath.Join(home, ".local", "bin", "claude-desktop"),
		}
	}
	if pathEnv := os.Getenv("PATH"); pathEnv != "" {
		name := "claude-desktop"
		if runtime.GOOS == "windows" {
			name = "claude-desktop.exe"
		}
		for _, dir := range strings.Split(pathEnv, string(os.PathListSeparator)) {
			candidates = append(candidates, filepath.Join(dir, name))
		}
	}
	for _, c := range candidates {
		if c == "" {
			continue
		}
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c, nil
		}
	}
	return "", errors.New("Claude Desktop could not be found. Install it from claude.com/download or set a custom path")
}

// isStoreAlias reports whether exe is the Microsoft Store shim. Kept (and
// tested) because it documents a real quirk: the alias also drops CLI flags
// at activation, so it can only ever open the main app.
func isStoreAlias(exe string) bool {
	return strings.EqualFold(filepath.Base(exe), "claude-desktop.exe") &&
		strings.Contains(strings.ToLower(exe), "windowsapps")
}

// DesktopDownloadURL is where the standalone Claude Desktop installer lives.
const DesktopDownloadURL = "https://claude.com/download"

// errDesktopInstallRequired is returned when a managed Desktop profile needs
// the Windows standalone-installer build and only the Store build (or
// nothing) is installed. Verified live: the standalone exe honors
// --user-data-dir and runs alongside the Store build.
var errDesktopInstallRequired = errors.New("separate Claude Desktop profiles need the standalone installer " +
	"version of Claude Desktop (the Microsoft Store version can't run extra profiles). " +
	"Install it from " + DesktopDownloadURL + " - you can keep the Store version too")

// findClassicDesktop locates the Windows standalone-installer build: custom
// path (unless it points into the Store package), then the newest
// AnthropicClaude/app-*/claude.exe, then other classic install locations.
func findClassicDesktop(custom string) (string, error) {
	isStorePath := func(p string) bool {
		return isStoreAlias(p) || strings.Contains(strings.ToLower(p), "windowsapps")
	}
	if custom != "" && !isStorePath(custom) {
		if st, err := os.Stat(custom); err == nil && !st.IsDir() {
			return custom, nil
		}
	}
	local := os.Getenv("LOCALAPPDATA")
	if local != "" {
		root := filepath.Join(local, "AnthropicClaude")
		if entries, err := os.ReadDir(root); err == nil {
			best, bestVer := "", []int(nil)
			for _, e := range entries {
				if !e.IsDir() || !strings.HasPrefix(e.Name(), "app-") {
					continue
				}
				exe := filepath.Join(root, e.Name(), "claude.exe")
				if _, err := os.Stat(exe); err != nil {
					continue
				}
				v := parseVersion(strings.TrimPrefix(e.Name(), "app-"))
				if best == "" || versionLess(bestVer, v) {
					best, bestVer = exe, v
				}
			}
			if best != "" {
				return best, nil
			}
		}
	}
	for _, c := range []string{
		filepath.Join(local, "Programs", "Claude", "Claude.exe"),
		filepath.Join(os.Getenv("ProgramFiles"), "Claude", "Claude.exe"),
	} {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c, nil
		}
	}
	return "", errDesktopInstallRequired
}

func parseVersion(s string) []int {
	var out []int
	for _, part := range strings.Split(s, ".") {
		n := 0
		for _, ch := range part {
			if ch < '0' || ch > '9' {
				break
			}
			n = n*10 + int(ch-'0')
		}
		out = append(out, n)
	}
	return out
}

func versionLess(a, b []int) bool {
	for i := 0; i < len(a) || i < len(b); i++ {
		var x, y int
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			return x < y
		}
	}
	return false
}

// userDataDirArg extracts --user-data-dir from argv in either the
// "--user-data-dir=<dir>" or "--user-data-dir <dir>" form.
func userDataDirArg(argv []string) (string, bool) {
	for i, a := range argv {
		if strings.HasPrefix(a, "--user-data-dir=") {
			return strings.TrimPrefix(a, "--user-data-dir="), true
		}
		if a == "--user-data-dir" && i+1 < len(argv) {
			return argv[i+1], true
		}
	}
	return "", false
}

// snapshotItem is what crosses into the detector: plain data, no store.
type snapshotItem struct {
	folder string
	dir    string
	system bool
	app    string
}

func snapshotItems(profiles []Profile, dirFor func(Profile) string) []snapshotItem {
	items := make([]snapshotItem, 0, len(profiles))
	for _, p := range profiles {
		items = append(items, snapshotItem{folder: p.FolderName, dir: dirFor(p), system: p.IsSystem, app: p.App})
	}
	return items
}

// isCursorMain mirrors the three apps' matcher, plus the hard-won guards:
// never match our own PID, and require a token boundary on the macOS
// executable path (…/CursorProfiles once SIGTERM'd Prism itself).
func isCursorMain(argv []string, selfPID int) bool {
	if len(argv) == 0 || argv[0] == "" {
		return false
	}
	exe := strings.ToLower(filepath.Base(argv[0]))
	if strings.Contains(exe, "prism") {
		return false
	}
	joined := strings.Join(argv, " ")
	var looks bool
	switch runtime.GOOS {
	case "darwin":
		if i := strings.Index(joined, ".app/Contents/MacOS/Cursor"); i >= 0 {
			rest := joined[i+len(".app/Contents/MacOS/Cursor"):]
			looks = rest == "" || strings.HasPrefix(rest, " ")
		} else {
			looks = exe == "cursor"
		}
	case "windows":
		looks = exe == "cursor.exe"
	default:
		looks = exe == "cursor" ||
			(strings.HasSuffix(exe, ".appimage") && strings.Contains(exe, "cursor"))
	}
	if !looks {
		return false
	}
	for _, a := range argv {
		if strings.HasPrefix(a, "--type=") {
			return false
		}
	}
	return true
}

func matchProfiles(items []snapshotItem, processes []procInfo, selfPID int) map[string][]int32 {
	out := make(map[string][]int32, len(items))
	for _, it := range items {
		var pids []int32
		switch it.app {
		case AppClaudeDesktop:
			pids = matchDesktop(it, processes, selfPID)
		case AppClaudeCode:
			// The CLI is a short-lived terminal process, not a persistent
			// GUI app: there is no reliable per-profile process to track
			// (no --user-data-dir in argv, env invisible to detectors),
			// so Code profiles report their launch history, not liveness.
			pids = nil
		default:
			pids = matchCursor(it, processes, selfPID)
		}
		out[it.folder] = pids
		sort.Slice(pids, func(i, j int) bool { return pids[i] < pids[j] })
	}
	return out
}

func matchCursor(it snapshotItem, processes []procInfo, selfPID int) []int32 {
	var pids []int32
	for _, pr := range processes {
		if pr.pid == int32(selfPID) {
			continue
		}
		if !isCursorMain(pr.argv, selfPID) {
			continue
		}
		hasUD := false
		udValue := ""
		for i, a := range pr.argv {
			if a == "--user-data-dir" && i+1 < len(pr.argv) {
				hasUD = true
				udValue = pr.argv[i+1]
				break
			}
		}
		if it.system {
			if !hasUD {
				pids = append(pids, pr.pid)
			}
		} else if hasUD && udValue == it.dir {
			pids = append(pids, pr.pid)
		}
	}
	return pids
}

// isDesktopMain mirrors isCursorMain for Claude Desktop. The bundled
// Claude Code helper is also named claude.exe on Windows, so any path
// containing "claude-code" is rejected — it belongs to a session, not to
// the Desktop app itself.
func isDesktopMain(argv []string, selfPID int) bool {
	if len(argv) == 0 || argv[0] == "" {
		return false
	}
	exe := strings.ToLower(filepath.Base(argv[0]))
	if strings.Contains(exe, "prism") {
		return false
	}
	joined := strings.Join(argv, " ")
	if strings.Contains(strings.ToLower(joined), "claude-code") {
		return false
	}
	var looks bool
	switch runtime.GOOS {
	case "darwin":
		// No bare-`claude` fallback: that name belongs to the Code CLI.
		// Desktop on macOS always runs from inside Claude.app.
		if i := strings.Index(joined, "Claude.app/Contents/MacOS/Claude"); i >= 0 {
			rest := joined[i+len("Claude.app/Contents/MacOS/Claude"):]
			looks = rest == "" || strings.HasPrefix(rest, " ")
		}
	case "windows":
		looks = exe == "claude.exe" || exe == "claude-desktop.exe"
	default:
		// No bare-`claude` fallback here either (Code CLI owns that name).
		looks = exe == "claude-desktop"
	}
	if !looks {
		return false
	}
	for _, a := range argv {
		if strings.HasPrefix(a, "--type=") {
			return false
		}
	}
	return true
}

func matchDesktop(it snapshotItem, processes []procInfo, selfPID int) []int32 {
	var pids []int32
	seenAnyDesktop := false
	for _, pr := range processes {
		if pr.pid == int32(selfPID) {
			continue
		}
		if !isDesktopMain(pr.argv, selfPID) {
			continue
		}
		seenAnyDesktop = true
		udValue, hasUD := userDataDirArg(pr.argv)
		if it.system {
			if !hasUD {
				pids = append(pids, pr.pid)
			}
		} else if hasUD && udValue == it.dir {
			pids = append(pids, pr.pid)
		}
	}
	if len(pids) == 0 && !it.system && seenAnyDesktop && desktopLockHeld(it.dir) {
		// Microsoft Store builds hide their command lines from process
		// enumeration, so --user-data-dir matching finds nothing. Electron
		// holds a lockfile inside a running user-data-dir: combined with a
		// live Desktop process, that identifies the running profile.
		pids = append(pids, -1)
	}
	return pids
}

// desktopLockHeld reports whether an Electron user-data-dir looks live.
// The -1 sentinel PID is never signaled; it only marks "running".
func desktopLockHeld(dir string) bool {
	st, err := os.Stat(filepath.Join(dir, "lockfile"))
	return err == nil && !st.IsDir()
}
