package main

// Overflow accounts for every app: a new profile that carries another
// profile's agents and config over, but never its identity. The new
// profile always starts signed out, with its own machine id, and you sign
// in with a different account on first launch.
//
// Each app keeps config and identity in different places, so each has its
// own carry-over rule. Rules are allowlists wherever the app mixes the two
// (Cursor, Claude Code, Claude Desktop): anything not listed stays behind,
// so an unknown new token file can never leak into an overflow profile.
// Grok Bot keeps config and identity in separate trees, so its rule is a
// denylist over the agent data root (see grokbot.go).
//
// Keep in sync with Sources/CursorProfiles/CarryOver.swift and
// linux/prism.py.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// cursorCarryOver: user settings, keybindings, tasks and snippets. Login
// tokens live in User/globalStorage/state.vscdb next to unrelated state,
// and the machine id in machineid/storage.json, so none of those travel.
// Extensions already live in ~/.cursor/extensions, shared by all profiles.
var cursorCarryOver = []string{
	"User/settings.json",
	"User/keybindings.json",
	"User/tasks.json",
	"User/snippets",
}

// desktopCarryOver: MCP servers/preferences and installed extensions with
// their settings. Sign-in lives in cookies and Chromium storage.
var desktopCarryOver = []string{
	"claude_desktop_config.json",
	"Claude Extensions",
	"Claude Extensions Settings",
}

// claudeCodeCarryOver: everything that shapes how Claude Code works for
// you. Credentials (.credentials.json, or the Keychain on macOS), session
// history, todos, shell snapshots and caches stay behind.
var claudeCodeCarryOver = []string{
	"settings.json",
	"CLAUDE.md",
	"keybindings.json",
	"agents",
	"commands",
	"skills",
	"output-styles",
	"hooks",
	"plugins",
}

// claudeCodeStateKeys: the parts of .claude.json that are preferences or
// user-scoped MCP servers. The rest of that file is account identity
// (oauthAccount, userID, …), per-project history and caches.
var claudeCodeStateKeys = []string{
	"mcpServers",
	"theme",
	"editorMode",
	"autoCompactEnabled",
	"verbose",
	"preferredNotifChannel",
}

// claudeCodeStateFile is where Claude Code keeps .claude.json for a config
// dir: inside it when CLAUDE_CONFIG_DIR points there, in $HOME otherwise.
func claudeCodeStateFile(configDir string, system bool) string {
	if system && os.Getenv("CLAUDE_CONFIG_DIR") == "" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".claude.json")
	}
	return filepath.Join(configDir, ".claude.json")
}

// carryOverSkipAnywhere: never copy lock or socket files.
func carryOverSkipAnywhere(name string) bool {
	return grokSkipAnywhere(name)
}

// copyTreeNoLinks copies a file or directory, skipping symlinks, special
// files and lock/socket files. Returns regular files copied.
func copyTreeNoLinks(src, dst string) (int, error) {
	st, err := os.Lstat(src)
	if err != nil {
		return 0, err
	}
	if st.Mode()&fs.ModeSymlink != 0 {
		return 0, nil
	}
	if st.Mode().IsRegular() {
		if carryOverSkipAnywhere(filepath.Base(src)) {
			return 0, nil
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
			return 0, err
		}
		return 1, copyFile(src, dst)
	}
	if !st.IsDir() {
		return 0, nil
	}
	copied := 0
	err = filepath.WalkDir(src, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if rel != "." && carryOverSkipAnywhere(d.Name()) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		target := filepath.Join(dst, rel)
		switch {
		case d.IsDir():
			return os.MkdirAll(target, 0o700)
		case d.Type().IsRegular():
			if err := copyFile(path, target); err != nil {
				return err
			}
			copied++
		}
		return nil
	})
	return copied, err
}

// carryOverAllowlist copies the listed slash-separated entries that exist.
func carryOverAllowlist(srcDir, dstDir string, entries []string) (int, error) {
	if !isDir(srcDir) {
		return 0, fmt.Errorf("nothing to carry over: %s does not exist", srcDir)
	}
	total := 0
	for _, rel := range entries {
		src := filepath.Join(srcDir, filepath.FromSlash(rel))
		if _, err := os.Lstat(src); err != nil {
			continue
		}
		n, err := copyTreeNoLinks(src, filepath.Join(dstDir, filepath.FromSlash(rel)))
		if err != nil {
			return total, err
		}
		total += n
	}
	return total, nil
}

// carryOverClaudeCode copies the config allowlist, the preference/MCP keys
// of .claude.json, and repoints plugin bookkeeping at the new dir.
func carryOverClaudeCode(srcDir, srcStateFile, dstDir string) (int, error) {
	n, err := carryOverAllowlist(srcDir, dstDir, claudeCodeCarryOver)
	if err != nil {
		return n, err
	}
	if err := rewritePluginPaths(filepath.Join(dstDir, "plugins"), srcDir, dstDir); err != nil {
		return n, err
	}
	wrote, err := carryOverClaudeState(srcStateFile, filepath.Join(dstDir, ".claude.json"))
	if err != nil {
		return n, err
	}
	if wrote {
		n++
	}
	return n, nil
}

// carryOverClaudeState writes only the allowlisted keys of .claude.json.
func carryOverClaudeState(src, dst string) (bool, error) {
	data, err := os.ReadFile(src)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(data, &all); err != nil {
		return false, fmt.Errorf("could not read %s: %w", src, err)
	}
	kept := map[string]json.RawMessage{}
	for _, k := range claudeCodeStateKeys {
		if v, ok := all[k]; ok {
			kept[k] = v
		}
	}
	if len(kept) == 0 {
		return false, nil
	}
	out, err := json.MarshalIndent(kept, "", "  ")
	if err != nil {
		return false, err
	}
	return true, os.WriteFile(dst, append(out, '\n'), 0o600)
}

// rewritePluginPaths: Claude Code records absolute install paths inside
// plugins/*.json. Point copies at the new profile, not the source's dir.
func rewritePluginPaths(pluginsDir, srcDir, dstDir string) error {
	if !isDir(pluginsDir) {
		return nil
	}
	quote := func(s string) string {
		b, _ := json.Marshal(s)
		return string(b[1 : len(b)-1])
	}
	pairs := []string{srcDir, dstDir}
	if q := quote(srcDir); q != srcDir {
		pairs = append(pairs, q, quote(dstDir))
	}
	replacer := strings.NewReplacer(pairs...)
	return filepath.WalkDir(pluginsDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(d.Name(), ".json") || !d.Type().IsRegular() {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if out := replacer.Replace(string(data)); out != string(data) {
			return os.WriteFile(path, []byte(out), 0o600)
		}
		return nil
	})
}

// CarryOver copies source's agents and config into dstDir (a new profile
// folder of the same app). Returns files copied.
func (s *Store) CarryOver(source Profile, dstDir string) (int, error) {
	srcDir := s.dirFor(source)
	switch source.App {
	case AppGrokBot:
		return CarryOverGrokData(grokDataRoot(srcDir, source.IsSystem), grokDataRoot(dstDir, false))
	case AppClaudeCode:
		return carryOverClaudeCode(srcDir, claudeCodeStateFile(srcDir, source.IsSystem), dstDir)
	case AppClaudeDesktop:
		return carryOverAllowlist(srcDir, dstDir, desktopCarryOver)
	default:
		return carryOverAllowlist(srcDir, dstDir, cursorCarryOver)
	}
}

// CreateOverflow creates a profile of source's app carrying over source's
// agents and config (any profile of that app, built-in included). On a
// failed copy the half-made profile is removed again.
func (s *Store) CreateOverflow(displayName, colorHex string, memoryMB int, projectPath string,
	source Profile) (*Profile, int, error) {
	p, err := s.CreateApp(displayName, source.App, colorHex, memoryMB, projectPath)
	if err != nil {
		return nil, 0, err
	}
	created := *p
	dir := s.dirFor(created)
	n, err := s.CarryOver(source, dir)
	if err != nil {
		_ = os.RemoveAll(dir)
		kept := s.Profiles[:0]
		for _, q := range s.Profiles {
			if q.FolderName != created.FolderName {
				kept = append(kept, q)
			}
		}
		s.Profiles = kept
		_ = s.save()
		return nil, 0, fmt.Errorf("could not carry over from %s: %w", source.DisplayName, err)
	}
	if created.App == AppCursor {
		// The copied settings.json carries the source's title bar color.
		_ = applyTitleBarColor(dir, created.ColorHex)
	}
	for i := range s.Profiles {
		if s.Profiles[i].FolderName == created.FolderName {
			return &s.Profiles[i], n, nil
		}
	}
	return &created, n, nil
}
