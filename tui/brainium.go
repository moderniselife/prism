package main

// Second brain: Prism wires Brainium (github.com/moderniselife/brainium)
// into every profile so agents share one git-backed memory across apps and
// accounts. Prism stays thin: it finds node and a Brainium checkout and runs
// its CLI. Brainium's own config (personal brain, capture, summarizer) is
// the single source of truth, shared with its hooks and MCP server.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

// Brainium is a resolved node + CLI pair.
type Brainium struct {
	Node string
	CLI  string
}

// BrainStatus is `brainium status --json`.
type BrainStatus struct {
	Version        string `json:"version"`
	PersonalBrain  string `json:"personalBrain"`
	PersonalExists bool   `json:"personalExists"`
	PersonalRemote string `json:"personalRemote"`
	Capture        bool   `json:"capture"`
	Pending        int    `json:"pending"`
	Summarizer     struct {
		Provider string `json:"provider"`
		Model    string `json:"model"`
	} `json:"summarizer"`
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// versionKey turns "v22.3.10" into a sortable key.
func versionKey(v string) string {
	parts := strings.Split(strings.TrimPrefix(v, "v"), ".")
	key := ""
	for _, p := range parts {
		n, _ := strconv.Atoi(p)
		key += fmt.Sprintf("%06d", n)
	}
	return key
}

// findNode locates node: custom path -> PATH -> version managers / installs.
// GUI-launched apps don't inherit the shell PATH, so the fallbacks matter.
func findNode(custom string) string {
	if custom != "" && isFile(custom) {
		return custom
	}
	if p, err := exec.LookPath("node"); err == nil {
		return p
	}
	home, _ := os.UserHomeDir()
	var candidates []string
	// nvm: newest installed version first.
	if dirs, _ := filepath.Glob(filepath.Join(home, ".nvm", "versions", "node", "*")); len(dirs) > 0 {
		sort.Slice(dirs, func(i, j int) bool {
			return versionKey(filepath.Base(dirs[i])) > versionKey(filepath.Base(dirs[j]))
		})
		for _, d := range dirs {
			candidates = append(candidates, filepath.Join(d, "bin", "node"))
		}
	}
	switch runtime.GOOS {
	case "windows":
		candidates = append(candidates,
			filepath.Join(os.Getenv("ProgramFiles"), "nodejs", "node.exe"),
			filepath.Join(os.Getenv("LOCALAPPDATA"), "Volta", "bin", "node.exe"))
	default:
		candidates = append(candidates, "/opt/homebrew/bin/node", "/usr/local/bin/node",
			filepath.Join(home, ".volta", "bin", "node"), "/usr/bin/node")
	}
	for _, c := range candidates {
		if isFile(c) {
			return c
		}
	}
	return ""
}

// findBrainiumCLI locates bin/brainium.mjs: custom (checkout dir or the
// script) -> $BRAINIUM_HOME -> common clone locations.
func findBrainiumCLI(custom string) string {
	home, _ := os.UserHomeDir()
	var dirs []string
	if custom != "" {
		if strings.HasSuffix(custom, ".mjs") && isFile(custom) {
			return custom
		}
		dirs = append(dirs, custom)
	}
	if env := os.Getenv("BRAINIUM_HOME"); env != "" {
		dirs = append(dirs, env)
	}
	for _, d := range []string{"brainium", "Projects/brainium", "src/brainium", "code/brainium", "Developer/brainium"} {
		dirs = append(dirs, filepath.Join(home, filepath.FromSlash(d)))
	}
	for _, d := range dirs {
		if cli := filepath.Join(d, "bin", "brainium.mjs"); isFile(cli) {
			return cli
		}
	}
	return ""
}

func (s *Store) brainium() (*Brainium, error) {
	node := findNode(s.nodePath)
	if node == "" {
		return nil, errors.New("Node.js not found — install it (nodejs.org) or set nodePath in settings")
	}
	cli := findBrainiumCLI(s.brainiumPath)
	if cli == "" {
		return nil, errors.New("Brainium not found — git clone https://github.com/moderniselife/brainium ~/brainium, or set brainiumPath")
	}
	return &Brainium{Node: node, CLI: cli}, nil
}

func (b *Brainium) run(args ...string) ([]byte, error) {
	cmd := exec.Command(b.Node, append([]string{b.CLI}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(ee.Stderr) > 0 {
			return out, errors.New(strings.TrimSpace(string(ee.Stderr)))
		}
		return out, err
	}
	return out, nil
}

// Status runs `brainium status --json`.
func (b *Brainium) Status() (*BrainStatus, error) {
	out, err := b.run("status", "--json")
	if err != nil {
		return nil, err
	}
	var st BrainStatus
	if err := json.Unmarshal(out, &st); err != nil {
		return nil, fmt.Errorf("unexpected brainium status output: %w", err)
	}
	return &st, nil
}

// brainWireArgs is the CLI call that wires one profile, or nil when the app
// has nothing local to wire (Grok Bot agents run in the cloud: they get an
// instructions snippet instead). Cursor's MCP config is global, so its
// profiles share one call.
func brainWireArgs(p Profile, dir string, capture bool) []string {
	switch p.App {
	case AppClaudeCode:
		args := []string{"wire", "--app", "claude-code", "--profile", dir, "--json"}
		if p.IsSystem {
			args = append(args, "--system")
		}
		if capture {
			args = append(args, "--capture")
		}
		return args
	case AppClaudeDesktop:
		return []string{"wire", "--app", "claude-desktop", "--profile", dir, "--json"}
	case AppCursor:
		return []string{"wire", "--app", "cursor", "--json"}
	default:
		return nil
	}
}

// WireBrain wires one profile into the second brain.
func (s *Store) WireBrain(p Profile) error {
	b, err := s.brainium()
	if err != nil {
		return err
	}
	st, err := b.Status()
	if err != nil {
		return err
	}
	args := brainWireArgs(p, s.dirFor(p), st.Capture)
	if args == nil {
		return nil
	}
	_, err = b.run(args...)
	return err
}

// WireAllBrains wires every profile; returns how many profiles were wired.
func (s *Store) WireAllBrains() (int, error) {
	b, err := s.brainium()
	if err != nil {
		return 0, err
	}
	st, err := b.Status()
	if err != nil {
		return 0, err
	}
	if !st.PersonalExists {
		return 0, fmt.Errorf("no personal brain yet — run: %s %s init-personal", b.Node, b.CLI)
	}
	wired, cursorDone := 0, false
	var errs []string
	for _, p := range s.Profiles {
		args := brainWireArgs(p, s.dirFor(p), st.Capture)
		if args == nil {
			continue
		}
		if p.App == AppCursor {
			if cursorDone {
				wired++
				continue
			}
			cursorDone = true
		}
		if _, err := b.run(args...); err != nil {
			errs = append(errs, fmt.Sprintf("%s: %v", p.DisplayName, err))
			continue
		}
		wired++
	}
	if len(errs) > 0 {
		return wired, errors.New(strings.Join(errs, "; "))
	}
	return wired, nil
}

// autoWireBrain wires a newly created profile when the user opted in.
func (s *Store) autoWireBrain(p Profile) {
	if s.brainAutoWire {
		_ = s.WireBrain(p)
	}
}
