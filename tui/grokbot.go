package main

// Grok Bot support: discovery, launch, process matching and the
// "overflow account" carry-over copy.
//
// Grok Bot is an Electron app whose main process honours SAND_USER_DATA_DIR
// in release builds: it becomes the app's userData *and* moves the agent
// data root from ~/.grokbot to <dir>/sand-data. The single-instance lock is
// taken after that switch, so each profile is its own instance with its
// own login. Prism also passes a matching --user-data-dir=<dir> (which the
// app keeps across its own relaunches) purely so the profile can be found
// again in the process list: environment variables are invisible there.
//
// Sign-in uses a browser round-trip that the app polls for, so several
// profiles can sign in to different accounts at the same time.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const AppGrokBot = "grok-bot"

// systemGrokFolderName marks the built-in Grok Bot profile (the app's own
// userData + ~/.grokbot). Never a real folder in the Grok Bot profiles dir.
const systemGrokFolderName = "__grok-bot-default__"

// grokUserDataEnv is the app's own isolation switch.
const grokUserDataEnv = "SAND_USER_DATA_DIR"

// grokDataSubdir is where the app keeps agents/settings inside an isolated
// user-data dir (the default install uses ~/.grokbot instead).
const grokDataSubdir = "sand-data"

func defaultGrokDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".grokbot_profiles"
	}
	return filepath.Join(home, ".grokbot_profiles")
}

// grokSystemUserData is Electron's default userData for the app
// (appData + productName).
func grokSystemUserData() string {
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "darwin":
		return filepath.Join(home, "Library", "Application Support", "Grok Bot")
	case "windows":
		if appdata := os.Getenv("APPDATA"); appdata != "" {
			return filepath.Join(appdata, "Grok Bot")
		}
		return filepath.Join(home, "AppData", "Roaming", "Grok Bot")
	default:
		if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
			return filepath.Join(xdg, "Grok Bot")
		}
		return filepath.Join(home, ".config", "Grok Bot")
	}
}

// grokSystemDataRoot is where the default install keeps agents and
// settings: ~/.grokbot, or the pre-rename ~/.cursor/sand on installs that
// never migrated.
func grokSystemDataRoot() string {
	home, _ := os.UserHomeDir()
	canonical := filepath.Join(home, ".grokbot")
	if isDir(canonical) {
		return canonical
	}
	legacy := filepath.Join(home, ".cursor", "sand")
	if isDir(legacy) {
		return legacy
	}
	return canonical
}

// grokDataRoot is a profile's agent data root.
func grokDataRoot(profileDir string, system bool) string {
	if system {
		return grokSystemDataRoot()
	}
	return filepath.Join(profileDir, grokDataSubdir)
}

func isDir(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

// findGrokBot locates the app: custom path -> well-known installs -> PATH.
func findGrokBot(custom string) (string, error) {
	if custom != "" {
		if st, err := os.Stat(custom); err == nil && !st.IsDir() {
			return custom, nil
		}
	}
	home, _ := os.UserHomeDir()
	var candidates []string
	name := "grok-bot"
	switch runtime.GOOS {
	case "darwin":
		candidates = []string{
			"/Applications/Grok Bot.app/Contents/MacOS/Grok Bot",
			filepath.Join(home, "Applications", "Grok Bot.app", "Contents", "MacOS", "Grok Bot"),
		}
	case "windows":
		name = "Grok Bot.exe"
		local, programs := os.Getenv("LOCALAPPDATA"), os.Getenv("ProgramFiles")
		candidates = []string{
			filepath.Join(local, "Programs", "Grok Bot", "Grok Bot.exe"),
			filepath.Join(local, "Programs", "grok-bot", "Grok Bot.exe"),
			filepath.Join(programs, "Grok Bot", "Grok Bot.exe"),
		}
	default:
		candidates = []string{
			"/usr/bin/grok-bot", "/usr/local/bin/grok-bot", "/opt/Grok Bot/grok-bot",
			filepath.Join(home, ".local", "bin", "grok-bot"),
		}
	}
	if pathEnv := os.Getenv("PATH"); pathEnv != "" {
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
	return "", errors.New("Grok Bot could not be found. Install it or set a custom path")
}

// grokLaunchArgsEnv returns the extra argv and environment for a profile.
// The built-in profile gets neither: byte-for-byte a normal launch.
func grokLaunchArgsEnv(profileDir string, system bool) (args, env []string) {
	if system {
		return nil, nil
	}
	return []string{"--user-data-dir=" + profileDir}, []string{grokUserDataEnv + "=" + profileDir}
}

func (s *Store) launchGrok(p Profile) error {
	exe, err := findGrokBot(s.customGrokPath)
	if err != nil {
		return err
	}
	dir := s.dirFor(p)
	if !p.IsSystem {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	args, extraEnv := grokLaunchArgsEnv(dir, p.IsSystem)
	cmd := exec.Command(exe, args...)
	// Never inherit a stray isolation switch from our own shell into the
	// built-in profile; managed profiles set their own below.
	env := make([]string, 0, len(os.Environ())+1)
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, grokUserDataEnv+"=") && !strings.HasPrefix(kv, "SAND_DATA_ROOT=") {
			env = append(env, kv)
		}
	}
	cmd.Env = append(env, extraEnv...)
	cmd.Stdout, cmd.Stderr = nil, nil
	cmd.SysProcAttr = detachAttr()
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to launch Grok Bot: %w", err)
	}
	return nil
}

// isGrokMain matches only the app's main process. Grok Bot also runs its
// local-exec daemon and agent coordinator through the *same* executable
// (ELECTRON_RUN_AS_NODE + a .cjs entry script), and Chromium helpers carry
// --type=; neither is the profile's window process.
func isGrokMain(argv []string) bool {
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
		const needle = "Grok Bot.app/Contents/MacOS/Grok Bot"
		if i := strings.Index(joined, needle); i >= 0 {
			rest := joined[i+len(needle):]
			looks = rest == "" || strings.HasPrefix(rest, " ")
		}
	case "windows":
		looks = exe == "grok bot.exe" || exe == "grok-bot.exe"
	default:
		looks = exe == "grok-bot" || exe == "grok bot"
	}
	if !looks {
		return false
	}
	for _, a := range argv[1:] {
		if strings.HasPrefix(a, "--type=") || strings.HasSuffix(a, ".cjs") ||
			strings.Contains(a, "app.asar") {
			return false
		}
	}
	return true
}

func matchGrok(it snapshotItem, processes []procInfo, selfPID int) []int32 {
	var pids []int32
	for _, pr := range processes {
		if pr.pid == int32(selfPID) || !isGrokMain(pr.argv) {
			continue
		}
		udValue, hasUD := userDataDirArg(pr.argv)
		if it.system {
			if !hasUD {
				pids = append(pids, pr.pid)
			}
		} else if hasUD && filepath.Clean(udValue) == filepath.Clean(it.dir) {
			pids = append(pids, pr.pid)
		}
	}
	return pids
}

// -- Overflow-account carry-over --------------------------------------------
//
// An overflow profile is a second account with the first one's local setup:
// settings, permission gates, tool approvals and MCP setup, but its own
// sign-in. Grok Bot's *agents* are not local: they live on the account's
// cloud box (/home/box/agent-data) and reach the app as a server roster,
// so no file copy can move them to another account. The app's own route is
// "Share with team" / clone-to-team on an agent. Only the agent data root
// is copied, and settings.json loses its account-scoped keys. Everything in
// Electron's userData is per-account or per-machine (Keychain-encrypted
// tokens and machine id in sand-secrets.json, user-secrets.json, cookies,
// account-scoped sand-client-persistence, automation webhook keys), so the
// new profile always starts signed out with a fresh machine identity.

// grokSkipTop are data-root entries that identify an account, a machine or
// a running instance. Matched by exact name, or name + "." (atomic-write
// temp files and backups such as mcp-auth.json.123).
var grokSkipTop = []string{
	".grokbot-data-root-v1",   // migration marker for the default root
	"host.lock",               // live-instance lock
	"host-token.json",         // host auth
	"host-secrets.json",       // host auth
	"gateway.json",            // local gateway token
	"gateway-descriptor.json", // local gateway endpoint
	"mcp-auth.json",           // MCP OAuth tokens of the source account
	"onepassword-oauth-states.json",
	"local-tool-spent-sends.json", // per-instance ledger
	"local-tool-retirements.json", // per-instance ledger
	"local-cua-helper.json",       // computer-use helper registration
	"recreate-intent.json",
	"recreate-resume.json",
	"desktop-status.json",
	"kept-update.json",
	"dev-box",      // local container state
	"computer-use", // helper runtime state
	"logs",
	"v8-code-cache",
}

// grokAccountSettingsKeys are the settings.json fields bound to the signed-
// in account or its cloud box; the rest of the file is preferences.
var grokAccountSettingsKeys = []string{
	"activeAccountScope",
	"hasSeenOnboardingAccountScope",
	"hasSeenOnboarding",
	"boxRosterCensus",
	"egressTunnelCommittedBoxUrls",
}

// scrubGrokSettings drops account-bound keys from a copied settings.json,
// keeping every other field (and its raw JSON) untouched.
func scrubGrokSettings(path string) error {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(data, &all); err != nil {
		// Unknown shape: never carry something we can't vet.
		return os.Remove(path)
	}
	for _, k := range grokAccountSettingsKeys {
		delete(all, k)
	}
	out, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(out, '\n'), 0o600)
}

// grokSkipTopPrefixes: the local-exec daemon's discovery file, credential,
// connection, lease and account-generation files are all bound to the
// running instance and its signed-in account.
var grokSkipTopPrefixes = []string{"local-exec-"}

// grokSkipAnywhere: lock/socket files at any depth.
func grokSkipAnywhere(name string) bool {
	lower := strings.ToLower(name)
	switch lower {
	case "lockfile", "singletonlock", "singletonsocket", "singletoncookie":
		return true
	}
	return strings.HasSuffix(lower, ".lock") || strings.HasSuffix(lower, ".sock") ||
		strings.HasSuffix(lower, ".pid")
}

// grokCarryOverSkips reports whether a data-root entry stays behind.
// rel is slash-separated and relative to the data root.
func grokCarryOverSkips(rel string) bool {
	parts := strings.Split(rel, "/")
	if grokSkipAnywhere(parts[len(parts)-1]) {
		return true
	}
	top := parts[0]
	for _, n := range grokSkipTop {
		if top == n || strings.HasPrefix(top, n+".") {
			return true
		}
	}
	for _, pre := range grokSkipTopPrefixes {
		if strings.HasPrefix(top, pre) {
			return true
		}
	}
	return false
}

// CarryOverGrokData copies agents and config from one data root to another,
// leaving identity, credentials and runtime state behind. Symlinks and
// special files are skipped (never followed). Returns files copied.
func CarryOverGrokData(srcRoot, dstRoot string) (int, error) {
	if !isDir(srcRoot) {
		return 0, fmt.Errorf("nothing to carry over: %s does not exist", srcRoot)
	}
	if err := os.MkdirAll(dstRoot, 0o700); err != nil {
		return 0, err
	}
	copied := 0
	err := filepath.WalkDir(srcRoot, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(srcRoot, path)
		if err != nil || rel == "." {
			return err
		}
		rel = filepath.ToSlash(rel)
		if grokCarryOverSkips(rel) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		target := filepath.Join(dstRoot, filepath.FromSlash(rel))
		switch {
		case d.IsDir():
			return os.MkdirAll(target, 0o700)
		case d.Type().IsRegular():
			if err := copyFile(path, target); err != nil {
				return err
			}
			copied++
		}
		// Symlinks, sockets, pipes: skipped.
		return nil
	})
	if err != nil {
		return copied, err
	}
	return copied, scrubGrokSettings(filepath.Join(dstRoot, "settings.json"))
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, st.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
