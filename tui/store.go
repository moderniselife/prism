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

type Profile struct {
	FolderName         string     `json:"folderName"`
	DisplayName        string     `json:"displayName"`
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
		ColorHex:           p.ColorHex,
		DefaultMemoryMB:    p.DefaultMemoryMB,
		DefaultProjectPath: p.DefaultProjectPath,
		IsPinned:           p.IsPinned,
		IsSystem:           p.IsSystem,
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
		ColorHex:           j.ColorHex,
		DefaultMemoryMB:    j.DefaultMemoryMB,
		DefaultProjectPath: j.DefaultProjectPath,
		IsPinned:           j.IsPinned,
		IsSystem:           j.IsSystem,
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
	if p.DefaultMemoryMB < 0 {
		return 0
	}
	return uint64(p.DefaultMemoryMB) * 1024 * 1024
}

type Store struct {
	Dir              string
	Profiles         []Profile
	defaultMemoryMB  int
	customCursorPath string
}

func defaultDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".cursor_profiles"
	}
	return filepath.Join(home, ".cursor_profiles")
}

func systemDataDir() string {
	home, _ := os.UserHomeDir()
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
	s := &Store{Dir: defaultDir(), defaultMemoryMB: 16384}
	if err := os.MkdirAll(s.Dir, 0o755); err != nil {
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
	if v, ok := raw["defaultMemoryMB"].(float64); ok && v >= 512 {
		s.defaultMemoryMB = int(v)
	}
}

func (s *Store) metadataPath() string {
	return filepath.Join(s.Dir, metadataName)
}

func (s *Store) dirFor(p Profile) string {
	if p.IsSystem {
		return systemDataDir()
	}
	return filepath.Join(s.Dir, p.FolderName)
}

func (s *Store) reload() error {
	var known []profileJSON
	if data, err := os.ReadFile(s.metadataPath()); err == nil {
		_ = json.Unmarshal(data, &known) // corrupt file: rebuild from disk
	}
	profiles := make([]Profile, 0, len(known))
	for _, j := range known {
		if j.FolderName == "" {
			continue
		}
		profiles = append(profiles, profileFromJSON(j))
	}

	entries, _ := os.ReadDir(s.Dir)
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
		if st, err := os.Stat(systemDataDir()); err == nil && st.IsDir() {
			profiles = append([]Profile{{
				FolderName:      systemFolderName,
				DisplayName:     "Main Cursor",
				ColorHex:        "#3B82F6",
				DefaultMemoryMB: 16384,
				CreatedAt:       time.Now().UTC(),
				IsPinned:        true,
				IsSystem:        true,
			}}, profiles...)
		}
	}

	s.Profiles = profiles
	return s.save()
}

func (s *Store) save() error {
	out := make([]profileJSON, 0, len(s.Profiles))
	for _, p := range s.Profiles {
		out = append(out, p.toJSON())
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.metadataPath(), append(data, '\n'), 0o644)
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
	folder, counter := base, 2
	for strings.ToLower(folder) == systemFolderName || existing[strings.ToLower(folder)] {
		folder = fmt.Sprintf("%s-%d", base, counter)
		counter++
	}
	return folder
}

func (s *Store) Create(displayName, colorHex string, memoryMB int, projectPath string) (*Profile, error) {
	base := sanitizeFolderName(strings.ReplaceAll(displayName, " ", "_"))
	if base == "" {
		return nil, errors.New("profile name must contain at least one letter, number, hyphen or underscore")
	}
	if memoryMB < 512 {
		memoryMB = 16384
	}
	p := Profile{
		FolderName:      s.uniqueFolderName(base),
		DisplayName:     strings.TrimSpace(displayName),
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
	_ = applyTitleBarColor(s.dirFor(p), p.ColorHex)
	s.Profiles = append(s.Profiles, p)
	if err := s.save(); err != nil {
		return nil, err
	}
	return &s.Profiles[len(s.Profiles)-1], nil
}

// Delete moves the profile folder to a timestamped trash directory inside
// ~/.cursor_profiles/.trash (hidden, so it is never re-adopted as a
// profile). Recoverable, unlike rm -rf.
func (s *Store) Delete(p Profile) error {
	if p.IsSystem {
		return errors.New("the built-in Cursor profile can't be deleted — it's your original Cursor data")
	}
	dir := s.dirFor(p)
	trash := filepath.Join(s.Dir, ".trash")
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

// Launch starts Cursor for the profile. Pass newWindow for a running
// profile — without it Cursor just refocuses and the click looks dead.
func (s *Store) Launch(p Profile, newWindow bool) error {
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
	now := time.Now().UTC()
	for i := range s.Profiles {
		if s.Profiles[i].FolderName == p.FolderName {
			s.Profiles[i].LastLaunchedAt = &now
			break
		}
	}
	return s.save()
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

// snapshotItem is what crosses into the detector: plain data, no store.
type snapshotItem struct {
	folder string
	dir    string
	system bool
}

func snapshotItems(profiles []Profile, dirFor func(Profile) string) []snapshotItem {
	items := make([]snapshotItem, 0, len(profiles))
	for _, p := range profiles {
		items = append(items, snapshotItem{folder: p.FolderName, dir: dirFor(p), system: p.IsSystem})
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
		out[it.folder] = pids
		sort.Slice(pids, func(i, j int) bool { return pids[i] < pids[j] })
	}
	return out
}
