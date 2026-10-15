package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestAppleEpoch(t *testing.T) {
	if got := timeToApple(time.Unix(0, 0).UTC()); got != -978307200 {
		t.Fatalf("unix 0 = %v apple seconds, want -978307200", got)
	}
	now := time.Now().UTC().Truncate(time.Second)
	if back := appleToTime(timeToApple(now)); !back.Equal(now) {
		t.Fatalf("round trip %v -> %v", now, back)
	}
}

func TestLegacyEmojiKeyIgnored(t *testing.T) {
	raw := `{"folderName":"x","displayName":"Work","emoji":"🚀","colorHex":"#FF0000",`
	raw += `"defaultMemoryMB":8192,"createdAt":778307200.0}`
	var j profileJSON
	if err := json.Unmarshal([]byte(raw), &j); err != nil {
		t.Fatal(err)
	}
	p := profileFromJSON(j)
	if p.DisplayName != "Work" || p.ColorHex != "#FF0000" || p.DefaultMemoryMB != 8192 {
		t.Fatalf("bad parse: %+v", p)
	}
	out, _ := json.Marshal(p.toJSON())
	if strings.Contains(string(out), "emoji") {
		t.Fatalf("emoji leaked into output: %s", out)
	}
}

func TestInitials(t *testing.T) {
	cases := map[string]string{"Main Cursor": "M", "  mojo layers": "M", "": "?", "   ": "?"}
	for in, want := range cases {
		if got := (Profile{DisplayName: in}).Initial(); got != want {
			t.Fatalf("initial(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSanitize(t *testing.T) {
	if got := sanitizeFolderName("a b-c_d!e+f"); got != "ab-c_def" {
		t.Fatalf("got %q", got)
	}
	if got := sanitizeFolderName("?!"); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestStripJSONComments(t *testing.T) {
	raw := "{\n// comment\n\"a\": 1, /* block */\n\"b\": [1, 2,],\n}"
	var v map[string]any
	if err := json.Unmarshal([]byte(stripJSONComments(raw)), &v); err != nil {
		t.Fatal(err)
	}
	if v["a"] != 1.0 || len(v["b"].([]any)) != 2 {
		t.Fatalf("bad merge: %v", v)
	}
}

func TestContrastingForeground(t *testing.T) {
	if contrastingForeground("#FFFFFF") != "#1A1A1A" {
		t.Fatal("white bg should get dark text")
	}
	if contrastingForeground("#000000") != "#FFFFFF" {
		t.Fatal("black bg should get light text")
	}
}

func TestAppDefaultsToCursor(t *testing.T) {
	var j profileJSON
	if err := json.Unmarshal([]byte(`{"folderName":"x","displayName":"Work"}`), &j); err != nil {
		t.Fatal(err)
	}
	if got := profileFromJSON(j).App; got != AppCursor {
		t.Fatalf("missing app = %q, want cursor", got)
	}
	var j2 profileJSON
	if err := json.Unmarshal([]byte(`{"folderName":"y","displayName":"Code","app":"claude-code"}`), &j2); err != nil {
		t.Fatal(err)
	}
	p := profileFromJSON(j2)
	if p.App != AppClaudeCode {
		t.Fatalf("app = %q, want claude-code", p.App)
	}
	out, _ := json.Marshal(p.toJSON())
	if !strings.Contains(string(out), `"app":"claude-code"`) {
		t.Fatalf("app missing from output: %s", out)
	}
	if got := (Profile{App: AppClaudeDesktop}).AppLabel(); got != "Desktop" {
		t.Fatalf("label = %q", got)
	}
}

func TestDesktopMatch(t *testing.T) {
	desktopExe := "/usr/bin/claude-desktop"
	if runtime.GOOS == "windows" {
		desktopExe = `C:\Program Files\Claude\claude.exe`
	}
	if runtime.GOOS == "darwin" {
		desktopExe = "/Applications/Claude.app/Contents/MacOS/Claude"
	}
	dir := "/tmp/fake-desktop-profile"
	if runtime.GOOS == "windows" {
		dir = `C:\tmp\fake-desktop-profile`
	}
	items := []snapshotItem{
		{folder: "d1", dir: dir, app: AppClaudeDesktop},
		{folder: "sys", dir: "", system: true, app: AppClaudeDesktop},
		{folder: "c1", dir: "/tmp/other", app: AppCursor},
	}
	procs := []procInfo{
		{pid: 11, argv: []string{desktopExe, "--user-data-dir", dir}},
		{pid: 12, argv: []string{desktopExe}},
		{pid: 13, argv: []string{desktopExe, "--type=renderer"}},
	}
	got := matchProfiles(items, procs, 999)
	if len(got["d1"]) != 1 || got["d1"][0] != 11 {
		t.Fatalf("desktop profile pids = %v", got["d1"])
	}
	if len(got["sys"]) != 1 || got["sys"][0] != 12 {
		t.Fatalf("desktop system pids = %v", got["sys"])
	}
	if len(got["c1"]) != 0 {
		t.Fatalf("cursor profile should not match desktop: %v", got["c1"])
	}
}

func TestDesktopMainExcludesClaudeCode(t *testing.T) {
	bundled := []string{`C:\Users\u\AppData\Roaming\Claude\claude-code\2.1.295\abc\claude.exe`}
	if isDesktopMain(bundled, 999) {
		t.Fatal("bundled claude-code exe must not count as Desktop")
	}
	cursorArgv := []string{"/usr/bin/cursor"}
	if runtime.GOOS == "windows" {
		cursorArgv = []string{`C:\Users\u\AppData\Local\Programs\cursor\Cursor.exe`}
	}
	if runtime.GOOS == "darwin" {
		cursorArgv = []string{"/Applications/Cursor.app/Contents/MacOS/Cursor"}
	}
	if !isCursorMain(cursorArgv, 999) {
		t.Fatal("sanity: cursor main matcher broken")
	}
}

func TestCodeNeverMatches(t *testing.T) {
	items := []snapshotItem{{folder: "code1", dir: "/tmp/code", app: AppClaudeCode}}
	procs := []procInfo{
		{pid: 21, argv: []string{"/usr/local/bin/claude"}},
		{pid: 22, argv: []string{"/usr/local/bin/claude", "--user-data-dir", "/tmp/code"}},
	}
	got := matchProfiles(items, procs, 999)
	if len(got["code1"]) != 0 {
		t.Fatalf("code profile must never match processes: %v", got["code1"])
	}
}

func TestIsStoreAlias(t *testing.T) {
	if !isStoreAlias(`C:\Users\u\AppData\Local\Microsoft\WindowsApps\claude-desktop.exe`) {
		t.Fatal("Store alias not recognized")
	}
	if isStoreAlias(`C:\Users\u\AppData\Local\Programs\Claude\Claude.exe`) {
		t.Fatal("classic install misread as Store alias")
	}
	if isStoreAlias("") || isStoreAlias("/usr/bin/claude-desktop") {
		t.Fatal("non-Windows paths must never count as Store aliases")
	}
}

func TestUserDataDirArg(t *testing.T) {
	if v, ok := userDataDirArg([]string{"claude", "--user-data-dir=/p/A"}); !ok || v != "/p/A" {
		t.Fatalf("= form: %q %v", v, ok)
	}
	if v, ok := userDataDirArg([]string{"claude", "--user-data-dir", "/p/B"}); !ok || v != "/p/B" {
		t.Fatalf("space form: %q %v", v, ok)
	}
	if _, ok := userDataDirArg([]string{"claude"}); ok {
		t.Fatal("no flag must not match")
	}
}

func TestFindClassicDesktopRejectsStorePath(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "WindowsApps", "Claude")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(dir, "Claude.exe")
	if err := os.WriteFile(exe, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOCALAPPDATA", t.TempDir())
	t.Setenv("ProgramFiles", t.TempDir())
	if got, _ := findClassicDesktop(exe); got == exe {
		t.Fatal("a Store-package path must not count as the standalone build")
	}
}

func TestVersionLess(t *testing.T) {
	if !versionLess(parseVersion("2.19675.1"), parseVersion("2.31226.1")) {
		t.Fatal("2.19675.1 should be older than 2.31226.1")
	}
	if versionLess(parseVersion("2.31226.1"), parseVersion("2.31226.1")) {
		t.Fatal("equal versions are not less")
	}
}
