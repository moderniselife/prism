package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestBrainWireArgs(t *testing.T) {
	code := brainWireArgs(Profile{App: AppClaudeCode}, "/p/Work", true)
	if strings.Join(code, " ") != "wire --app claude-code --profile /p/Work --json --capture" {
		t.Fatalf("claude-code args = %v", code)
	}
	sys := brainWireArgs(Profile{App: AppClaudeCode, IsSystem: true}, "/home/u/.claude", false)
	if strings.Join(sys, " ") != "wire --app claude-code --profile /home/u/.claude --json --system" {
		t.Fatalf("built-in claude-code args = %v", sys)
	}
	if got := brainWireArgs(Profile{App: AppClaudeDesktop}, "/d", true); strings.Join(got, " ") != "wire --app claude-desktop --profile /d --json" {
		t.Fatalf("desktop args = %v", got)
	}
	if got := brainWireArgs(Profile{App: AppCursor}, "/c", true); strings.Join(got, " ") != "wire --app cursor --json" {
		t.Fatalf("cursor args = %v", got)
	}
	if brainWireArgs(Profile{App: AppGrokBot}, "/g", true) != nil {
		t.Fatal("Grok Bot has nothing local to wire")
	}
}

func TestFindBrainiumCLI(t *testing.T) {
	dir := t.TempDir()
	cli := filepath.Join(dir, "bin", "brainium.mjs")
	if err := os.MkdirAll(filepath.Dir(cli), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cli, []byte("//"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := findBrainiumCLI(dir); got != cli {
		t.Fatalf("checkout dir: %q", got)
	}
	if got := findBrainiumCLI(cli); got != cli {
		t.Fatalf("script path: %q", got)
	}
	t.Setenv("BRAINIUM_HOME", dir)
	if got := findBrainiumCLI(""); got != cli {
		t.Fatalf("BRAINIUM_HOME: %q", got)
	}
}

func TestVersionKeyOrdersNodeVersions(t *testing.T) {
	if !(versionKey("v22.3.0") > versionKey("v20.18.1") && versionKey("v20.18.1") > versionKey("v20.9.0")) {
		t.Fatal("nvm versions must sort numerically, newest first")
	}
}

// Integration: drive the real Brainium CLI when a checkout is available
// (BRAINIUM_HOME or a common clone location) and node is installed.
func TestWireAllBrainsWithRealBrainium(t *testing.T) {
	cli := findBrainiumCLI("")
	node := findNode("")
	if cli == "" || node == "" {
		t.Skip("no Brainium checkout / node available")
	}
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	base := t.TempDir()
	t.Setenv("BRAINIUM_CONFIG", filepath.Join(base, "brainium.json"))
	t.Setenv("HOME", base) // keeps Cursor's ~/.cursor/mcp.json inside the sandbox
	for _, kv := range [][2]string{{"GIT_AUTHOR_NAME", "T"}, {"GIT_AUTHOR_EMAIL", "t@e.x"}, {"GIT_COMMITTER_NAME", "T"}, {"GIT_COMMITTER_EMAIL", "t@e.x"}} {
		t.Setenv(kv[0], kv[1])
	}
	b := &Brainium{Node: node, CLI: cli}
	if _, err := b.run("init-personal", filepath.Join(base, "Brain")); err != nil {
		t.Fatal(err)
	}
	if _, err := b.run("config", "set", "capture", "true"); err != nil {
		t.Fatal(err)
	}

	s := testStore(t)
	s.brainiumPath = cli
	s.nodePath = node
	code, _ := s.CreateApp("Work", AppClaudeCode, "", 0, "")
	desk, _ := s.CreateApp("Desk", AppClaudeDesktop, "", 0, "")
	_, _ = s.CreateApp("Ed", AppCursor, "", 8192, "")
	_, _ = s.CreateApp("Ed2", AppCursor, "", 8192, "")
	_, _ = s.CreateApp("Grok", AppGrokBot, "", 0, "")

	n, err := s.WireAllBrains()
	if err != nil {
		t.Fatal(err)
	}
	if n != 4 {
		t.Fatalf("wired %d profiles, want 4 (Grok Bot gets a snippet instead)", n)
	}
	var settings struct {
		Hooks map[string][]struct {
			Hooks []struct{ Command string } `json:"hooks"`
		} `json:"hooks"`
	}
	data, err := os.ReadFile(filepath.Join(s.dirFor(*code), "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &settings); err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(settings.Hooks["SessionEnd"][0].Hooks[0].Command, " capture") {
		t.Fatalf("capture hook missing: %s", data)
	}
	for _, f := range []string{
		filepath.Join(s.dirFor(*code), "skills", "brainium", "SKILL.md"),
		filepath.Join(s.dirFor(*code), ".claude.json"),
		filepath.Join(s.dirFor(*desk), "claude_desktop_config.json"),
		filepath.Join(base, ".cursor", "mcp.json"),
	} {
		if _, err := os.Stat(f); err != nil {
			t.Fatalf("not wired: %s", f)
		}
	}
}
