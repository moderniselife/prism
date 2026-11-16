package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/moderniselife/prism/tui/endpoint"
)

// The Endpoint screen (E): Prism's local OpenAI/Anthropic API that sends
// requests with the keys of an identity. Start/stop it, switch identity,
// add identities and keys, and watch spend and recent requests.

type epStatusMsg struct {
	status  *endpoint.Status
	running bool
	err     string
}

type epState struct {
	open    bool
	cfg     endpoint.Config
	status  *endpoint.Status
	running bool
	sel     int

	// Prompts: "name" (new identity), "provider", "url", "key", "model".
	prompt   string
	buf      string
	provider endpoint.Provider
	url      string
}

func epFetch() tea.Msg {
	st, err := endpoint.FetchStatus(endpoint.ConfigPath())
	if err != nil {
		return epStatusMsg{err: err.Error()}
	}
	return epStatusMsg{status: &st, running: true}
}

func (m *model) epReloadConfig() {
	cfg, err := endpoint.Load(endpoint.ConfigPath())
	if err != nil {
		m.setStatus("Endpoint settings: " + err.Error())
	}
	m.ep.cfg = cfg
	if m.ep.sel >= len(cfg.Identities) {
		m.ep.sel = len(cfg.Identities) - 1
	}
	if m.ep.sel < 0 {
		m.ep.sel = 0
	}
}

func (m *model) epSave() bool {
	if err := endpoint.Save(endpoint.ConfigPath(), m.ep.cfg); err != nil {
		m.setStatus("Couldn't save endpoint settings: " + err.Error())
		return false
	}
	if m.ep.running {
		_, _ = endpoint.Admin(endpoint.ConfigPath(), "POST", "/prism/reload", nil)
	}
	return true
}

func (m *model) epSelected() *endpoint.Identity {
	if m.ep.sel >= 0 && m.ep.sel < len(m.ep.cfg.Identities) {
		return &m.ep.cfg.Identities[m.ep.sel]
	}
	return nil
}

// epStart runs this binary's "endpoint serve" in the background.
func (m *model) epStart() {
	exe, err := os.Executable()
	if err != nil {
		m.setStatus("Couldn't start the endpoint: " + err.Error())
		return
	}
	if !m.ep.cfg.Enabled {
		m.ep.cfg.Enabled = true
		m.epSave()
	}
	cmd := exec.Command(exe, "endpoint", "serve")
	cmd.SysProcAttr = detachAttr()
	if err := cmd.Start(); err != nil {
		m.setStatus("Couldn't start the endpoint: " + err.Error())
		return
	}
	_ = cmd.Process.Release()
	m.setStatus(fmt.Sprintf("Endpoint starting on http://127.0.0.1:%d/v1", m.ep.cfg.Port))
}

func (m *model) epStop() {
	if _, err := endpoint.Admin(endpoint.ConfigPath(), "POST", "/prism/stop", nil); err != nil {
		m.setStatus(err.Error())
		return
	}
	m.ep.cfg.Enabled = false
	m.epSave()
	m.ep.running = false
	m.setStatus("Endpoint stopped.")
}

func (m model) epKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.ep.prompt != "" {
		return m.epPromptKey(msg)
	}
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "esc", "E":
		m.ep.open = false
	case "up", "k":
		if m.ep.sel > 0 {
			m.ep.sel--
		}
	case "down", "j":
		if m.ep.sel < len(m.ep.cfg.Identities)-1 {
			m.ep.sel++
		}
	case "enter", " ":
		if id := m.epSelected(); id != nil {
			m.ep.cfg.ActiveIdentityID = id.ID
			if m.epSave() {
				m.setStatus("Now using " + id.Name + ".")
			}
			return m, epFetch
		}
	case "s":
		if m.ep.running {
			m.epStop()
		} else {
			m.epStart()
		}
		return m, tea.Tick(800*time.Millisecond, func(time.Time) tea.Msg { return epFetch() })
	case "a":
		m.ep.prompt, m.ep.buf = "name", ""
	case "p":
		if m.epSelected() != nil {
			m.ep.prompt, m.ep.provider = "provider", endpoint.Anthropic
		}
	case "m":
		if id := m.epSelected(); id != nil {
			m.ep.prompt, m.ep.buf = "model", id.DefaultModel
		}
	case "t":
		m.ep.cfg.TagsEnabled = !m.ep.cfg.TagsEnabled
		m.epSave()
	case "c":
		m.setStatus(fmt.Sprintf("Base URL http://127.0.0.1:%d/v1 · API key %s", m.ep.cfg.Port, m.ep.cfg.Token))
	}
	return m, nil
}

func (m model) epPromptKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()
	if key == "esc" {
		m.ep.prompt = ""
		return m, nil
	}
	if m.ep.prompt == "provider" {
		i := 0
		for j, p := range endpoint.Providers {
			if p == m.ep.provider {
				i = j
			}
		}
		switch key {
		case "left", "h", "shift+tab":
			m.ep.provider = endpoint.Providers[(i+len(endpoint.Providers)-1)%len(endpoint.Providers)]
		case "right", "l", "tab":
			m.ep.provider = endpoint.Providers[(i+1)%len(endpoint.Providers)]
		case "enter":
			m.ep.buf = ""
			if m.ep.provider == endpoint.Compatible {
				m.ep.prompt = "url"
			} else {
				m.ep.prompt = "key"
			}
		}
		return m, nil
	}
	switch msg.Type {
	case tea.KeyEnter:
		return m.epSubmit()
	case tea.KeyBackspace:
		if r := []rune(m.ep.buf); len(r) > 0 {
			m.ep.buf = string(r[:len(r)-1])
		}
	case tea.KeySpace:
		m.ep.buf += " "
	case tea.KeyRunes:
		m.ep.buf += string(msg.Runes)
	case tea.KeyCtrlU:
		m.ep.buf = ""
	}
	return m, nil
}

func (m model) epSubmit() (tea.Model, tea.Cmd) {
	val := strings.TrimSpace(m.ep.buf)
	switch m.ep.prompt {
	case "name":
		m.ep.prompt = ""
		if val == "" || endpoint.Slugify(val) == "" {
			return m, nil
		}
		for _, id := range m.ep.cfg.Identities {
			if id.Slug() == endpoint.Slugify(val) {
				m.setStatus("There's already an identity called @" + id.Slug() + ".")
				return m, nil
			}
		}
		colors := []string{"#3B82F6", "#F43F5E", "#10B981", "#F59E0B", "#8B5CF6", "#14B8A6"}
		m.ep.cfg.Identities = append(m.ep.cfg.Identities, endpoint.Identity{
			ID: endpoint.NewID(), Name: val, ColorHex: colors[len(m.ep.cfg.Identities)%len(colors)], Token: endpoint.NewToken(),
		})
		if m.ep.cfg.ActiveIdentityID == "" {
			m.ep.cfg.ActiveIdentityID = m.ep.cfg.Identities[0].ID
		}
		if m.ep.cfg.Token == "" {
			m.ep.cfg.Token = endpoint.NewToken()
		}
		m.ep.sel = len(m.ep.cfg.Identities) - 1
		m.epSave()
		m.setStatus("Added " + val + ". Press p to add a provider key.")
	case "url":
		m.ep.url = val
		m.ep.prompt, m.ep.buf = "key", ""
	case "key":
		m.ep.prompt = ""
		id := m.epSelected()
		if id == nil {
			return m, nil
		}
		if val == "" && m.ep.provider.KeyRequired() {
			m.setStatus("No key entered.")
			return m, nil
		}
		var cred *endpoint.Credential
		for i := range id.Credentials {
			if id.Credentials[i].Provider == m.ep.provider && m.ep.provider != endpoint.Compatible {
				cred = &id.Credentials[i]
			}
		}
		if cred == nil {
			id.Credentials = append(id.Credentials, endpoint.Credential{ID: endpoint.NewID(), Provider: m.ep.provider, BaseURL: m.ep.url})
			cred = &id.Credentials[len(id.Credentials)-1]
		}
		keys := endpoint.NewKeys(endpoint.Dir())
		if err := keys.Set(cred.ID, val); err != nil {
			m.setStatus("Couldn't store the key: " + err.Error())
			return m, nil
		}
		if !m.epSave() {
			return m, nil
		}
		where := "the system keyring"
		if keys.UsingFile {
			where = "a private file (no system keyring found)"
		}
		m.setStatus(fmt.Sprintf("Saved %s's %s key in %s.", id.Name, m.ep.provider.Label(), where))
		m.ep.url = ""
		return m, epFetch
	case "model":
		m.ep.prompt = ""
		if id := m.epSelected(); id != nil {
			id.DefaultModel = val
			m.epSave()
		}
	}
	return m, nil
}

func (m model) epView() string {
	var b strings.Builder
	cfg := m.ep.cfg
	state := fg(colDim, false).Render("○ Off")
	if m.ep.running {
		state = fg(colGreen, false).Render("●") + " " + fg(colSub, false).Render(fmt.Sprintf("Running on http://127.0.0.1:%d/v1", cfg.Port))
	}
	b.WriteString(" " + fg(colText, true).Render("Endpoint") + "  " + state + "\n")
	b.WriteString(" " + fg(colMute, false).Render("Point apps at it with the token as API key · models prism, work/…, personal/… · switch mid-chat with @work") + "\n\n")

	if len(cfg.Identities) == 0 {
		b.WriteString(" " + fg(colSub, false).Render("No identities yet. Press a to add one (for example Work), then p to add its API key.") + "\n")
	}
	stats := map[string]endpoint.IdentityStatus{}
	if m.ep.status != nil {
		for _, s := range m.ep.status.Identities {
			stats[s.ID] = s
		}
	}
	active := cfg.Active()
	for i, id := range cfg.Identities {
		cursor := "  "
		if i == m.ep.sel {
			cursor = fg(colAccent, true).Render("› ")
		}
		dot := lipgloss.NewStyle().Foreground(lipgloss.Color(id.ColorHex)).Render("●")
		name := fg(colText, i == m.ep.sel).Render(padRight(id.Name, 12))
		tag := fg(colMute, false).Render(padRight("@"+id.Slug(), 12))
		var provs []string
		for _, c := range id.Credentials {
			l := c.Provider.Label()
			if s, ok := stats[id.ID]; ok && c.Provider.KeyRequired() && !s.Keys[c.ID] {
				l += " (no key)"
			}
			provs = append(provs, l)
		}
		detail := strings.Join(provs, " · ")
		if detail == "" {
			detail = "no providers — press p"
		}
		if id.DefaultModel != "" {
			detail += " · default " + id.DefaultModel
		}
		line := " " + cursor + dot + " " + name + tag + fg(colSub, false).Render(truncate(detail, 46))
		if active != nil && active.ID == id.ID {
			line += "  " + fg(colAccent, true).Render("active")
		}
		if s, ok := stats[id.ID]; ok {
			spend := fmt.Sprintf("  $%.2f this month", s.MonthCost)
			if s.Budget > 0 {
				spend += fmt.Sprintf(" of $%.0f", s.Budget)
			}
			line += fg(colMute, false).Render(spend)
			if s.CooldownUntil != nil {
				line += " " + fg(colAmber, false).Render("rate-limited until "+s.CooldownUntil.Local().Format("15:04"))
			}
		}
		b.WriteString(line + "\n")
	}

	switch m.ep.prompt {
	case "name":
		b.WriteString("\n " + fg(colDim, false).Render("New identity name ") + m.ep.buf + fg(colAccent, true).Render("█") + "\n")
	case "provider":
		var opts []string
		for _, p := range endpoint.Providers {
			if p == m.ep.provider {
				opts = append(opts, fg(colAccent, true).Render("["+p.Label()+"]"))
			} else {
				opts = append(opts, fg(colSub, false).Render(" "+p.Label()+" "))
			}
		}
		b.WriteString("\n " + fg(colDim, false).Render("Provider ") + strings.Join(opts, " ") + fg(colMute, false).Render("  ←/→ choose · enter") + "\n")
	case "url":
		b.WriteString("\n " + fg(colDim, false).Render("Server URL (e.g. http://bonsai.local:8080/v1) ") + m.ep.buf + fg(colAccent, true).Render("█") + "\n")
	case "key":
		b.WriteString("\n " + fg(colDim, false).Render(m.ep.provider.Label()+" API key ") + strings.Repeat("•", len([]rune(m.ep.buf))) + fg(colAccent, true).Render("█") + "\n")
	case "model":
		b.WriteString("\n " + fg(colDim, false).Render("Default model ") + m.ep.buf + fg(colAccent, true).Render("█") + "\n")
	}

	if m.ep.status != nil && len(m.ep.status.Log) > 0 {
		b.WriteString("\n " + fg(colSub, true).Render("Recent requests") + "\n")
		rows := m.height - 18 - len(cfg.Identities)
		if rows < 3 {
			rows = 3
		}
		for i, l := range m.ep.status.Log {
			if i >= rows {
				break
			}
			status := fg(colGreen, false).Render(fmt.Sprint(l.Status))
			if l.Status >= 400 {
				status = fg(colRed, false).Render(fmt.Sprint(l.Status))
			}
			extra := l.Reason
			if l.Note != "" {
				extra = l.Note
			}
			if l.Error != "" {
				extra = l.Error
			}
			cost := ""
			if l.Cost != nil && *l.Cost > 0 {
				cost = fmt.Sprintf(" $%.4f", *l.Cost)
			}
			b.WriteString(fmt.Sprintf(" %s  %s %s %s%s  %s\n", fg(colMute, false).Render(l.Date.Local().Format("15:04:05")),
				fg(colText, false).Render(padRight(l.Identity, 10)), padRight(truncate(l.Model, 28), 28), status,
				fg(colMute, false).Render(cost), fg(colDim, false).Render(truncate(extra, 40))))
		}
	}
	return b.String()
}

func epHints(m model) string {
	if m.ep.prompt != "" {
		return "enter save · esc cancel"
	}
	toggle := "s start"
	if m.ep.running {
		toggle = "s stop"
	}
	tags := "t tags on"
	if m.ep.cfg.TagsEnabled {
		tags = "t tags off"
	}
	return "enter use identity · " + toggle + " · a add identity · p add key · m default model · " + tags + " · c show token · esc back"
}
