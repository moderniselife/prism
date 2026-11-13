package main

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

func TestGrokAppRoundTrip(t *testing.T) {
	if normalizeApp(AppGrokBot) != AppGrokBot {
		t.Fatal("grok-bot must survive normalization")
	}
	if got := profileFromJSON(profileJSON{FolderName: "g", App: AppGrokBot}).App; got != AppGrokBot {
		t.Fatalf("loaded app = %q", got)
	}
	if (Profile{App: AppGrokBot, DefaultMemoryMB: 8192}).LimitBytes() != 0 {
		t.Fatal("Grok Bot has no memory cap")
	}
	if systemMarkerFor(AppGrokBot) != systemGrokFolderName {
		t.Fatal("wrong built-in marker")
	}
}

func TestGrokLaunchArgsEnv(t *testing.T) {
	args, env := grokLaunchArgsEnv("/p/Work", false)
	if len(args) != 1 || args[0] != "--user-data-dir=/p/Work" {
		t.Fatalf("args = %v", args)
	}
	if len(env) != 1 || env[0] != "SAND_USER_DATA_DIR=/p/Work" {
		t.Fatalf("env = %v", env)
	}
	if a, e := grokLaunchArgsEnv("/ignored", true); a != nil || e != nil {
		t.Fatal("built-in profile must launch exactly like a normal open")
	}
}

func TestGrokCarryOverSkips(t *testing.T) {
	skipped := []string{
		"host.lock", "host-token.json", "host-secrets.json", "gateway.json",
		"gateway-descriptor.json", "mcp-auth.json", "mcp-auth.json.1234",
		"local-exec-daemon.json", "local-exec-daemon-credential.json",
		"local-exec-account-generation.json", "dev-box", "dev-box/gateway.json",
		"computer-use/helper.json", ".grokbot-data-root-v1", "agents/run-1/state.lock",
		"agents/x.sock", "logs/main.log",
	}
	for _, rel := range skipped {
		if !grokCarryOverSkips(rel) {
			t.Errorf("%s must stay behind", rel)
		}
	}
	kept := []string{
		"agents", "agents/a1/agent.json", "settings.json", "local-tool-approvals.json",
		"local-tool-standing-grants.v1.json", "obsidian-vault.json", "plugins/x/plugin.json",
		"skills/s/SKILL.md", "agents/host.lock.md",
	}
	for _, rel := range kept {
		if grokCarryOverSkips(rel) {
			t.Errorf("%s must carry over", rel)
		}
	}
}

func TestCarryOverGrokData(t *testing.T) {
	src := t.TempDir()
	write := func(rel, body string) {
		p := filepath.Join(src, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("settings.json", `{"theme":"dark"}`)
	write("agents/a1/agent.json", `{"name":"Researcher"}`)
	write("skills/s/SKILL.md", "# skill")
	write("host-secrets.json", "SECRET")
	write("mcp-auth.json", "TOKENS")
	write("local-exec-daemon-credential.json", "CRED")
	write("host.lock", "")
	write("dev-box/big.img", "xxxx")
	if runtime.GOOS != "windows" {
		if err := os.Symlink("/etc/passwd", filepath.Join(src, "agents", "link")); err != nil {
			t.Fatal(err)
		}
	}

	dst := filepath.Join(t.TempDir(), "Overflow", grokDataSubdir)
	n, err := CarryOverGrokData(src, dst)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	_ = filepath.Walk(dst, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			rel, _ := filepath.Rel(dst, p)
			got = append(got, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Strings(got)
	want := []string{"agents/a1/agent.json", "settings.json", "skills/s/SKILL.md"}
	if strings.Join(got, ",") != strings.Join(want, ",") || n != len(want) {
		t.Fatalf("copied %d %v, want %v", n, got, want)
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "agents", "a1", "agent.json")); string(b) != `{"name":"Researcher"}` {
		t.Fatalf("content mismatch: %q", b)
	}
	if _, err := CarryOverGrokData(filepath.Join(src, "nope"), dst); err == nil {
		t.Fatal("missing source must be an error, not a silent empty profile")
	}
}

func TestCreateGrokOverflow(t *testing.T) {
	base := t.TempDir()
	s := &Store{
		Dir: filepath.Join(base, "c"), CodeDir: filepath.Join(base, "cc"),
		DesktopDir: filepath.Join(base, "cd"), GrokDir: filepath.Join(base, "g"),
		defaultMemoryMB: 16384,
	}
	for _, d := range []string{s.Dir, s.CodeDir, s.DesktopDir, s.GrokDir} {
		_ = os.MkdirAll(d, 0o755)
	}
	src, err := s.CreateApp("Primary", AppGrokBot, "#6366F1", 0, "")
	if err != nil {
		t.Fatal(err)
	}
	srcRoot := grokDataRoot(s.dirFor(*src), false)
	_ = os.MkdirAll(filepath.Join(srcRoot, "agents"), 0o700)
	_ = os.WriteFile(filepath.Join(srcRoot, "agents", "a.json"), []byte("{}"), 0o600)
	_ = os.WriteFile(filepath.Join(srcRoot, "host-token.json"), []byte("tok"), 0o600)
	// Identity in userData must never travel either.
	_ = os.WriteFile(filepath.Join(s.dirFor(*src), "sand-secrets.json"), []byte("enc"), 0o600)

	over, n, err := s.CreateGrokOverflow("Overflow", "#10B981", *src)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 || over.App != AppGrokBot {
		t.Fatalf("n=%d app=%s", n, over.App)
	}
	dir := s.dirFor(*over)
	if _, err := os.Stat(filepath.Join(dir, grokDataSubdir, "agents", "a.json")); err != nil {
		t.Fatal("agent not carried over")
	}
	for _, leaked := range []string{
		filepath.Join(dir, grokDataSubdir, "host-token.json"),
		filepath.Join(dir, "sand-secrets.json"),
	} {
		if _, err := os.Stat(leaked); err == nil {
			t.Fatalf("identity leaked: %s", leaked)
		}
	}

	// Failed copy rolls the half-made profile back.
	empty, _ := s.CreateApp("Empty", AppGrokBot, "", 0, "")
	before := len(s.Profiles)
	if _, _, err := s.CreateGrokOverflow("Broken", "", *empty); err == nil {
		t.Fatal("carry-over from a profile with no data root must fail")
	}
	if len(s.Profiles) != before {
		t.Fatal("failed overflow left a profile behind")
	}
	if _, err := os.Stat(filepath.Join(s.GrokDir, "Broken")); err == nil {
		t.Fatal("failed overflow left its folder behind")
	}
}

func TestMatchGrok(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("argv shapes below are macOS/Linux")
	}
	exe := "/usr/bin/grok-bot"
	if runtime.GOOS == "darwin" {
		exe = "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot"
	}
	items := []snapshotItem{
		{folder: systemGrokFolderName, dir: "/sys", system: true, app: AppGrokBot},
		{folder: "Work", dir: "/p/Work", app: AppGrokBot},
	}
	procs := []procInfo{
		{pid: 1, argv: []string{exe}},
		{pid: 2, argv: []string{exe, "--user-data-dir=/p/Work"}},
		{pid: 3, argv: []string{exe, "--type=renderer", "--user-data-dir=/p/Work"}},
		// local-exec daemon: same executable run as node with a .cjs entry.
		{pid: 4, argv: []string{exe, "/x/app.asar/dist/local-exec-daemon/entry.cjs"}},
		{pid: 5, argv: []string{"/Applications/Prism.app/Contents/MacOS/Prism"}},
	}
	got := matchProfiles(items, procs, 999)
	if len(got[systemGrokFolderName]) != 1 || got[systemGrokFolderName][0] != 1 {
		t.Fatalf("built-in = %v", got[systemGrokFolderName])
	}
	if len(got["Work"]) != 1 || got["Work"][0] != 2 {
		t.Fatalf("Work = %v", got["Work"])
	}
}
