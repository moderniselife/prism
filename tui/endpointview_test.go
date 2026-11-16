package main

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/moderniselife/prism/tui/endpoint"
)

func TestEndpointView(t *testing.T) {
	t.Setenv("PRISM_ENDPOINT_DIR", t.TempDir())
	m := newModel(&Store{})
	m.width, m.height = 120, 40
	next, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("E")})
	m = next.(model)
	if !m.ep.open {
		t.Fatal("E should open the endpoint screen")
	}
	if !strings.Contains(m.View(), "No identities yet") {
		t.Fatalf("empty state missing:\n%s", m.View())
	}
	// Add "Work" through the prompt.
	next, _ = m.epKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("a")})
	m = next.(model)
	for _, r := range "Work" {
		next, _ = m.epKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		m = next.(model)
	}
	next, _ = m.epKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)
	cfg, _ := endpoint.Load(endpoint.ConfigPath())
	if len(cfg.Identities) != 1 || cfg.Identities[0].Name != "Work" || cfg.ActiveIdentityID != cfg.Identities[0].ID {
		t.Fatalf("identity not saved: %+v", cfg)
	}
	// Show a status with spend and a log line.
	cost := 0.0123
	until := time.Now().Add(time.Minute)
	m.ep.running = true
	m.ep.status = &endpoint.Status{Identities: []endpoint.IdentityStatus{{ID: cfg.Identities[0].ID, MonthCost: 12.5, Budget: 50, CooldownUntil: &until, Keys: map[string]bool{}}},
		Log: []endpoint.LogEntry{{Date: time.Now(), Identity: "Work", Model: "claude-sonnet-5", Status: 200, Cost: &cost, Note: "Work rate-limited (429) → Personal"}}}
	v := m.View()
	for _, want := range []string{"Running on http://127.0.0.1:4848/v1", "@work", "active", "$12.50 this month of $50", "rate-limited until", "Recent requests", "claude-sonnet-5"} {
		if !strings.Contains(v, want) {
			t.Errorf("view missing %q:\n%s", want, v)
		}
	}
	t.Log("\n" + v)
}
