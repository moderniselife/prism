package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	base := t.TempDir()
	s := &Store{
		Dir: filepath.Join(base, "c"), CodeDir: filepath.Join(base, "cc"),
		DesktopDir: filepath.Join(base, "cd"), GrokDir: filepath.Join(base, "g"),
		defaultMemoryMB: 16384,
	}
	for _, d := range []string{s.Dir, s.CodeDir, s.DesktopDir, s.GrokDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return s
}

func put(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func filesUnder(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	_ = filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			rel, _ := filepath.Rel(root, p)
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Strings(out)
	return out
}

func TestOverflowCursor(t *testing.T) {
	s := testStore(t)
	src, _ := s.CreateApp("Work", AppCursor, "#6366F1", 8192, "")
	dir := s.dirFor(*src)
	put(t, dir, "User/settings.json", `{"editor.fontSize": 15}`)
	put(t, dir, "User/keybindings.json", `[]`)
	put(t, dir, "User/snippets/go.json", `{}`)
	put(t, dir, "User/globalStorage/state.vscdb", "AUTH TOKENS")
	put(t, dir, "User/globalStorage/storage.json", `{"telemetry.machineId":"x"}`)
	put(t, dir, "User/workspaceStorage/abc/state.vscdb", "history")
	put(t, dir, "machineid", "x")
	put(t, dir, "Cookies", "c")

	over, n, err := s.CreateOverflow("Overflow", "#10B981", 8192, "", *src)
	if err != nil {
		t.Fatal(err)
	}
	got := filesUnder(t, s.dirFor(*over))
	want := []string{"User/keybindings.json", "User/settings.json", "User/snippets/go.json"}
	if strings.Join(got, ",") != strings.Join(want, ",") || n != 3 {
		t.Fatalf("n=%d got %v want %v", n, got, want)
	}
	// Settings kept, but recolored for the new profile.
	b, _ := os.ReadFile(filepath.Join(s.dirFor(*over), "User", "settings.json"))
	if !strings.Contains(string(b), `"editor.fontSize": 15`) || !strings.Contains(strings.ToUpper(string(b)), "#10B981") {
		t.Fatalf("settings not carried/recolored: %s", b)
	}
}

func TestOverflowClaudeDesktop(t *testing.T) {
	s := testStore(t)
	src, _ := s.CreateApp("Main", AppClaudeDesktop, "", 0, "")
	dir := s.dirFor(*src)
	put(t, dir, "claude_desktop_config.json", `{"mcpServers":{}}`)
	put(t, dir, "Claude Extensions/ext1/manifest.json", `{}`)
	put(t, dir, "Claude Extensions Settings/ext1.json", `{}`)
	put(t, dir, "Cookies", "session")
	put(t, dir, "Local Storage/leveldb/000003.log", "state")
	put(t, dir, "config.json", `{"oauth":"x"}`)

	over, n, err := s.CreateOverflow("Two", "", 0, "", *src)
	if err != nil {
		t.Fatal(err)
	}
	got := filesUnder(t, s.dirFor(*over))
	want := []string{"Claude Extensions Settings/ext1.json", "Claude Extensions/ext1/manifest.json", "claude_desktop_config.json"}
	if strings.Join(got, ",") != strings.Join(want, ",") || n != 3 {
		t.Fatalf("n=%d got %v want %v", n, got, want)
	}
}

func TestFreshDesktopStartsEmpty(t *testing.T) {
	s := testStore(t)
	p, err := s.CreateApp("Fresh", AppClaudeDesktop, "", 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := filesUnder(t, s.dirFor(*p)); len(got) != 0 {
		t.Fatalf("fresh profile must start empty, got %v", got)
	}
}

func TestOverflowClaudeCode(t *testing.T) {
	s := testStore(t)
	src, _ := s.CreateApp("Main", AppClaudeCode, "", 0, "")
	dir := s.dirFor(*src)
	put(t, dir, "settings.json", `{"model":"opus"}`)
	put(t, dir, "CLAUDE.md", "# me")
	put(t, dir, "agents/reviewer.md", "agent")
	put(t, dir, "commands/ship.md", "cmd")
	put(t, dir, "skills/s/SKILL.md", "skill")
	put(t, dir, "plugins/installed_plugins.json",
		`{"plugins":{"x":{"installPath":"`+filepath.ToSlash(filepath.Join(dir, "plugins", "cache", "x"))+`"}}}`)
	put(t, dir, ".credentials.json", `{"claudeAiOauth":{"accessToken":"SECRET"}}`)
	put(t, dir, "projects/-Users-joe-app/session.jsonl", "transcript")
	put(t, dir, "history.jsonl", "prompts")
	put(t, dir, "todos/t.json", "[]")
	put(t, dir, ".claude.json", `{"oauthAccount":{"emailAddress":"a@b.c"},"userID":"u1",`+
		`"mcpServers":{"gh":{"command":"gh-mcp"}},"theme":"dark","projects":{"/x":{}}}`)

	over, n, err := s.CreateOverflow("Overflow", "", 0, "", *src)
	if err != nil {
		t.Fatal(err)
	}
	odir := s.dirFor(*over)
	got := filesUnder(t, odir)
	want := []string{".claude.json", "CLAUDE.md", "agents/reviewer.md", "commands/ship.md",
		"plugins/installed_plugins.json", "settings.json", "skills/s/SKILL.md"}
	if strings.Join(got, ",") != strings.Join(want, ",") || n != len(want) {
		t.Fatalf("n=%d got %v want %v", n, got, want)
	}
	var state map[string]any
	b, _ := os.ReadFile(filepath.Join(odir, ".claude.json"))
	if err := json.Unmarshal(b, &state); err != nil {
		t.Fatal(err)
	}
	if _, ok := state["oauthAccount"]; ok {
		t.Fatal("account identity leaked into .claude.json")
	}
	if _, ok := state["userID"]; ok {
		t.Fatal("user id leaked into .claude.json")
	}
	if _, ok := state["projects"]; ok {
		t.Fatal("project history leaked into .claude.json")
	}
	if state["theme"] != "dark" || state["mcpServers"] == nil {
		t.Fatalf("preferences/MCP not carried: %v", state)
	}
	pb, _ := os.ReadFile(filepath.Join(odir, "plugins", "installed_plugins.json"))
	if strings.Contains(string(pb), filepath.ToSlash(dir)+"/") || !strings.Contains(string(pb), filepath.ToSlash(odir)) {
		t.Fatalf("plugin paths not repointed: %s", pb)
	}
}

func TestClaudeCodeStateFileLocation(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	home, _ := os.UserHomeDir()
	if got := claudeCodeStateFile("/x/.claude", true); got != filepath.Join(home, ".claude.json") {
		t.Fatalf("built-in profile state = %s", got)
	}
	if got := claudeCodeStateFile("/p/Work", false); got != filepath.Join("/p/Work", ".claude.json") {
		t.Fatalf("managed profile state = %s", got)
	}
}

func TestOverflowMissingSourceRollsBack(t *testing.T) {
	s := testStore(t)
	ghost := Profile{FolderName: "Ghost", DisplayName: "Ghost", App: AppCursor}
	before := len(s.Profiles)
	if _, _, err := s.CreateOverflow("Broken", "", 8192, "", ghost); err == nil {
		t.Fatal("overflow from a missing source must fail")
	}
	if len(s.Profiles) != before || isDir(filepath.Join(s.Dir, "Broken")) {
		t.Fatal("failed overflow left a profile behind")
	}
}
