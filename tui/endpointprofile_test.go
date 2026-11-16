package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/moderniselife/prism/tui/endpoint"
)

// A profile's API account (set in the macOS/Windows/Linux apps) survives the
// TUI rewriting .profiles.json, and the Claude Code command uses it.
func TestEndpointIdentityRoundTripAndCommand(t *testing.T) {
	p := Profile{FolderName: "work", DisplayName: "Work", App: AppClaudeCode, EndpointIdentity: "ID1"}
	if got := profileFromJSON(p.toJSON()).EndpointIdentity; got != "ID1" {
		t.Fatalf("endpointIdentity lost: %q", got)
	}

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "endpoint.json")
	t.Setenv("PRISM_ENDPOINT_CONFIG", cfgPath)
	cfg := endpoint.Defaults()
	cfg.Port = 5151
	cfg.Token = "prism-main"
	cfg.Identities = []endpoint.Identity{{ID: "ID1", Name: "Work", Token: "prism-work"}}
	if err := endpoint.Save(cfgPath, cfg); err != nil {
		t.Fatal(err)
	}
	s := &Store{CodeDir: filepath.Join(dir, "code")}
	cmd := s.CodeCommand(p)
	for _, want := range []string{`ANTHROPIC_BASE_URL="http://127.0.0.1:5151"`, `ANTHROPIC_AUTH_TOKEN="prism-work"`, " claude"} {
		if !strings.Contains(cmd, want) {
			t.Fatalf("command %q missing %q", cmd, want)
		}
	}
	p.EndpointIdentity = "*"
	if cmd := s.CodeCommand(p); !strings.Contains(cmd, `"prism-main"`) {
		t.Fatalf("active identity should use the main token: %q", cmd)
	}
	p.EndpointIdentity = ""
	if cmd := s.CodeCommand(p); strings.Contains(cmd, "ANTHROPIC") {
		t.Fatalf("own sign-in should not set API env: %q", cmd)
	}
	_ = os.Remove(cfgPath)
}
