package main

// Bubble Tea interface: filterable profile list, launch/stop/new/delete,
// live stats, status bar. No emoji anywhere — initial-letter tiles, like
// the apps since the great de-emojification.

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// Palette mirrors PrismTheme (foregrounds only — no background fills, so
// the TUI stays legible on any terminal theme).
var (
	colText = lipgloss.AdaptiveColor{Light: "#10151F", Dark: "#F2F4F8"}
	colDim  = lipgloss.AdaptiveColor{Light: "#646D7D", Dark: "#8E97A8"}
	colMute = lipgloss.AdaptiveColor{Light: "#8B94A4", Dark: "#6E7789"}

	colCyan   = lipgloss.Color("#22D3EE")
	colPurple = lipgloss.Color("#A78BFA")
	colPink   = lipgloss.Color("#F472B6")
	colGreen  = lipgloss.Color("#34D399")
	colAmber  = lipgloss.Color("#FBBF24")
	colRed    = lipgloss.Color("#F87171")
)

func fg(c lipgloss.TerminalColor, bold bool) lipgloss.Style {
	s := lipgloss.NewStyle().Foreground(c)
	if bold {
		s = s.Bold(true)
	}
	return s
}

type tickMsg time.Time

type snapshotMsg struct {
	running map[string][]int32
	rss     map[string]uint64
	sizes   map[string]uint64 // nil unless full rescan
	cpu     float64
	cpuOK   bool
	at      time.Time
}

type model struct {
	store    *Store
	profiles []Profile
	sizes    map[string]uint64
	running  map[string][]int32
	rss      map[string]uint64
	cpu      float64
	cpuOK    bool
	totalMem uint64

	sel       string // selected FolderName
	offset    int
	filter    string
	filtering bool

	formActive bool
	formFocus  int // 0 name, 1 memory, 2 project
	formVals   [3]string

	confirmDelete string

	width, height int
	status        string
	statusAt      time.Time
}

func newModel(store *Store) model {
	profs := append([]Profile(nil), store.Profiles...)
	sel := ""
	if len(profs) > 0 {
		sel = profs[0].FolderName
	}
	return model{
		store:    store,
		profiles: profs,
		sizes:    map[string]uint64{},
		running:  map[string][]int32{},
		rss:      map[string]uint64{},
		totalMem: totalMemory(),
		sel:      sel,
		width:    100,
		height:   30,
	}
}

func tickCmd() tea.Msg {
	return tea.Tick(4*time.Second, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})()
}

// refreshCmd snapshots profiles first: the scan runs off the main goroutine
// and must not race with create/delete.
func (m *model) refreshCmd(full bool) tea.Cmd {
	profs := append([]Profile(nil), m.profiles...)
	items := snapshotItems(profs, m.store.dirFor)
	st := m.store
	_ = st
	return func() tea.Msg {
		procs := listProcesses()
		running := matchProfiles(items, procs, os.Getpid())
		rss := make(map[string]uint64, len(running))
		for folder, pids := range running {
			rss[folder] = rssOfPids(pids)
		}
		var sizes map[string]uint64
		if full {
			sizes = make(map[string]uint64, len(items))
			for _, it := range items {
				sizes[it.folder] = diskUsage(it.dir)
			}
		}
		cpu, ok := cpuSample()
		return snapshotMsg{running: running, rss: rss, sizes: sizes, cpu: cpu, cpuOK: ok, at: time.Now()}
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.refreshCmd(true), tickCmd)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		if msg.Width > 0 {
			m.width = msg.Width
		}
		if msg.Height > 0 {
			m.height = msg.Height
		}
		return m, nil
	case tickMsg:
		return m, tea.Batch(m.refreshCmd(false), tickCmd)
	case snapshotMsg:
		m.running = msg.running
		m.rss = msg.rss
		if msg.sizes != nil {
			m.sizes = msg.sizes
		}
		if msg.cpuOK {
			m.cpu, m.cpuOK = msg.cpu, true
		}
		m.ensureSelection()
		return m, nil
	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

// -- selection & filtering -------------------------------------------------

func (m *model) visible() []Profile {
	f := strings.ToLower(m.filter)
	out := m.profiles[:0:0]
	for _, p := range m.profiles {
		if f != "" && !strings.Contains(strings.ToLower(p.DisplayName), f) &&
			!strings.Contains(strings.ToLower(p.FolderName), f) {
			continue
		}
		out = append(out, p)
	}
	return out
}

func (m *model) selected() *Profile {
	for i := range m.visible() {
		if m.visible()[i].FolderName == m.sel {
			v := m.visible()[i]
			return &v
		}
	}
	return nil
}

func (m *model) ensureSelection() {
	vis := m.visible()
	if len(vis) == 0 {
		m.sel = ""
		m.offset = 0
		return
	}
	idx := 0
	found := false
	for i, p := range vis {
		if p.FolderName == m.sel {
			idx, found = i, true
			break
		}
	}
	if !found {
		m.sel = vis[0].FolderName
		idx = 0
	}
	m.clampScroll(idx, len(vis))
}

func (m *model) moveSelection(delta int) {
	vis := m.visible()
	if len(vis) == 0 {
		return
	}
	idx := 0
	for i, p := range vis {
		if p.FolderName == m.sel {
			idx = i
			break
		}
	}
	idx += delta
	if idx < 0 {
		idx = 0
	}
	if idx >= len(vis) {
		idx = len(vis) - 1
	}
	m.sel = vis[idx].FolderName
	m.confirmDelete = ""
	m.clampScroll(idx, len(vis))
}

func (m *model) maxRows() int {
	rows := m.height - 8
	if rows < 1 {
		rows = 1
	}
	return rows
}

func (m *model) clampScroll(idx, total int) {
	rows := m.maxRows()
	if idx < m.offset {
		m.offset = idx
	}
	if idx >= m.offset+rows {
		m.offset = idx - rows + 1
	}
	if m.offset > total-rows {
		m.offset = total - rows
	}
	if m.offset < 0 {
		m.offset = 0
	}
}

func (m *model) setStatus(s string) {
	m.status = s
	m.statusAt = time.Now()
}

// -- keys ------------------------------------------------------------------

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.formActive {
		return m.formKey(msg)
	}
	if m.filtering {
		return m.filterKey(msg)
	}
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "up", "k":
		m.moveSelection(-1)
	case "down", "j":
		m.moveSelection(1)
	case "/":
		m.filtering = true
		m.confirmDelete = ""
	case "enter":
		m.doLaunch()
		return m, m.refreshCmd(false)
	case "x":
		m.doStop()
		return m, m.refreshCmd(false)
	case "n":
		m.formActive = true
		m.formFocus = 0
		m.formVals = [3]string{"", "16384", ""}
		m.confirmDelete = ""
	case "d":
		m.doDelete()
	case "R":
		m.rescan()
		return m, m.refreshCmd(true)
	case "esc":
		m.confirmDelete = ""
	}
	return m, nil
}

func (m model) filterKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.filtering = false
		m.filter = ""
		m.ensureSelection()
	case "enter":
		m.filtering = false
		m.ensureSelection()
	case "backspace":
		if m.filter != "" {
			r := []rune(m.filter)
			m.filter = string(r[:len(r)-1])
			m.ensureSelection()
		}
	default:
		if len(msg.Runes) == 1 {
			m.filter += string(msg.Runes)
			m.ensureSelection()
		}
	}
	return m, nil
}

func (m model) formKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.formActive = false
		return m, nil
	case "ctrl+s":
		m.doSaveForm()
		return m, m.refreshCmd(true)
	case "tab", "enter":
		if m.formFocus == 2 {
			m.doSaveForm()
			return m, m.refreshCmd(true)
		}
		m.formFocus++
		return m, nil
	case "shift+tab":
		m.formFocus = (m.formFocus + 2) % 3
		return m, nil
	case "backspace":
		v := m.formVals[m.formFocus]
		if v != "" {
			r := []rune(v)
			m.formVals[m.formFocus] = string(r[:len(r)-1])
		}
		return m, nil
	case "ctrl+u":
		m.formVals[m.formFocus] = ""
		return m, nil
	default:
		if len(msg.Runes) == 1 {
			m.formVals[m.formFocus] += string(msg.Runes)
		}
		return m, nil
	}
}

// -- actions ---------------------------------------------------------------

func (m *model) profileByFolder(folder string) *Profile {
	for i := range m.profiles {
		if m.profiles[i].FolderName == folder {
			return &m.profiles[i]
		}
	}
	return nil
}

func (m *model) doLaunch() {
	p := m.selected()
	if p == nil {
		return
	}
	cp := *p
	if err := m.store.Launch(cp, len(m.running[cp.FolderName]) > 0); err != nil {
		m.setStatus("Launch failed: " + err.Error())
		return
	}
	m.setStatus("Launched " + cp.DisplayName)
	m.profiles = append([]Profile(nil), m.store.Profiles...)
}

func (m *model) doStop() {
	p := m.selected()
	if p == nil {
		return
	}
	pids := m.running[p.FolderName]
	if len(pids) == 0 {
		m.setStatus(p.DisplayName + " is not running")
		return
	}
	quitPIDs(pids)
	m.setStatus(fmt.Sprintf("Stopped %s (%d process)", p.DisplayName, len(pids)))
}

func (m *model) doDelete() {
	p := m.selected()
	if p == nil {
		return
	}
	if p.IsSystem {
		m.setStatus("The built-in profile can't be deleted")
		return
	}
	if len(m.running[p.FolderName]) > 0 {
		m.setStatus("Quit it before deleting")
		return
	}
	if m.confirmDelete != p.FolderName {
		m.confirmDelete = p.FolderName
		m.setStatus("Press d again to move " + p.DisplayName + " to trash")
		return
	}
	m.confirmDelete = ""
	if err := m.store.Delete(*p); err != nil {
		m.setStatus("Delete failed: " + err.Error())
		return
	}
	m.setStatus("Moved " + p.DisplayName + " to trash")
	m.profiles = append([]Profile(nil), m.store.Profiles...)
	m.ensureSelection()
}

func (m *model) doSaveForm() {
	name := strings.TrimSpace(m.formVals[0])
	if name == "" {
		m.setStatus("Give the profile a name")
		return
	}
	mem, err := strconv.Atoi(strings.TrimSpace(m.formVals[1]))
	if err != nil || mem < 512 {
		m.setStatus("Memory must be a number >= 512")
		return
	}
	if _, err := m.store.Create(name, accentFor(name), mem, strings.TrimSpace(m.formVals[2])); err != nil {
		m.setStatus("Create failed: " + err.Error())
		return
	}
	m.setStatus("Created " + name)
	m.formActive = false
	m.profiles = append([]Profile(nil), m.store.Profiles...)
	for _, p := range m.profiles {
		if p.DisplayName == name {
			m.sel = p.FolderName
			break
		}
	}
	m.ensureSelection()
}

func (m *model) rescan() {
	if err := m.store.reload(); err != nil {
		m.setStatus("Rescan failed: " + err.Error())
		return
	}
	m.profiles = append([]Profile(nil), m.store.Profiles...)
	m.setStatus("Rescanned profiles")
	m.ensureSelection()
}

// -- view ------------------------------------------------------------------

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	if n <= 1 {
		return "…"
	}
	return string(r[:n-1]) + "…"
}

func formatBytes(b uint64) string {
	const unit = 1024.0
	if b < 1024 {
		return fmt.Sprintf("%d B", b)
	}
	v, u := float64(b)/unit, "KB"
	for _, next := range []string{"MB", "GB", "TB"} {
		if v < unit {
			break
		}
		v /= unit
		u = next
	}
	s := fmt.Sprintf("%.1f", v)
	return strings.TrimSuffix(s, ".0") + " " + u
}

func memBar(frac float64, width int) string {
	if width < 2 {
		return ""
	}
	full := int(frac*float64(width) + 0.5)
	if full > width {
		full = width
	}
	filled := fg(colCyan, false).Render(strings.Repeat("█", full))
	empty := fg(colMute, false).Render(strings.Repeat("░", width-full))
	return filled + empty
}

func (m model) headerView() string {
	running := 0
	var live uint64
	for _, p := range m.profiles {
		if pids := m.running[p.FolderName]; len(pids) > 0 {
			running++
			live += m.rss[p.FolderName]
		}
	}
	left := fg(colText, true).Render("▲ Prism") + " " +
		fg(colCyan, false).Render("v"+displayVersion())
	var right string
	if running > 0 {
		right = fg(colGreen, false).Render(
			fmt.Sprintf("● %d running · %s live", running, formatBytes(live)))
	} else {
		right = fg(colDim, false).Render("Idle")
	}
	w := m.width
	if w < 20 {
		w = 20
	}
	gap := w - lipgloss.Width(left) - lipgloss.Width(right) - 2
	if gap < 1 {
		gap = 1
	}
	return " " + left + strings.Repeat(" ", gap) + right
}

func (m model) filterView() string {
	if m.filtering {
		return " " + fg(colDim, false).Render("Filter: ") + m.filter +
			fg(colCyan, true).Render("█")
	}
	active := 0
	for _, p := range m.profiles {
		if len(m.running[p.FolderName]) > 0 {
			active++
		}
	}
	info := fmt.Sprintf("%d profiles · %d running · / to filter", len(m.profiles), active)
	return " " + fg(colMute, false).Render(info)
}

func profileRow(m model, p Profile, selected bool) string {
	pids := m.running[p.FolderName]
	running := len(pids) > 0
	live := m.rss[p.FolderName]
	limit := p.LimitBytes()

	marker := "  "
	nameStyle := fg(colText, selected)
	if selected {
		marker = fg(colCyan, true).Render("▸ ")
	}
	tile := fg(lipgloss.Color(p.ColorHex), true).Render(" " + p.Initial() + " ")
	name := nameStyle.Render(truncate(p.DisplayName, 28))

	tags := ""
	if p.IsSystem {
		tags += fg(colDim, false).Render(" [BUILT-IN]")
	}
	if p.IsPinned && !p.IsSystem {
		tags += fg(colDim, false).Render(" [PINNED]")
	}

	var status string
	if running {
		status = fg(colGreen, false).Render("● Running") + " " +
			fg(colDim, false).Render(fmt.Sprintf("PID %d", pids[0]))
	} else {
		status = fg(colDim, false).Render("○ Idle")
	}

	path := ""
	if p.DefaultProjectPath != nil && *p.DefaultProjectPath != "" {
		path = " " + fg(colDim, false).Render(truncate(*p.DefaultProjectPath, 32))
	}

	var meminfo string
	var frac float64
	if running {
		meminfo = fg(lipgloss.Color(p.ColorHex), true).Render(formatBytes(live)) + " " +
			fg(colDim, false).Render("/ "+formatBytes(limit)+" limit")
		if limit > 0 {
			frac = float64(live) / float64(limit)
			if frac > 1 {
				frac = 1
			}
		}
	} else {
		meminfo = fg(colDim, false).Render(formatBytes(limit) + " limit")
	}

	line1 := marker + tile + " " + name + tags
	line2 := "    " + status + path
	line3 := "    " + fg(colDim, false).Render("Memory ") + meminfo + "  " + memBar(frac, 10)
	return line1 + "\n" + line2 + "\n" + line3
}

func (m model) listView() string {
	vis := m.visible()
	if len(vis) == 0 {
		return "\n  " + fg(colDim, false).Render("No profiles match.") + "\n"
	}
	rows := m.maxRows() / 3
	if rows < 1 {
		rows = 1
	}
	start, end := m.offset, m.offset+rows
	if start > len(vis) {
		start = len(vis)
	}
	if end > len(vis) {
		end = len(vis)
	}
	blocks := make([]string, 0, end-start)
	for _, p := range vis[start:end] {
		blocks = append(blocks, profileRow(m, p, p.FolderName == m.sel))
	}
	more := ""
	if end < len(vis) {
		more = "\n  " + fg(colDim, false).Render(fmt.Sprintf("… %d more", len(vis)-end))
	}
	if start > 0 {
		blocks = append([]string{"  " + fg(colDim, false).Render(fmt.Sprintf("… %d above", start))}, blocks...)
	}
	return "\n" + strings.Join(blocks, "\n\n") + more + "\n"
}

func (m model) formView() string {
	titles := []string{"Profile name", "Memory limit (MB)", "Project folder (optional)"}
	hints := "tab next · enter next/save · esc cancel"
	var b strings.Builder
	b.WriteString("\n  " + fg(colText, true).Render("New profile") + "\n\n")
	for i, t := range titles {
		head := fg(colDim, false).Render("  " + t)
		if i == m.formFocus {
			head = fg(colCyan, true).Render("▸ " + t)
		}
		val := m.formVals[i]
		if i == m.formFocus {
			val += fg(colCyan, true).Render("█")
		}
		if val == "" && i != m.formFocus {
			val = fg(colMute, false).Render("—")
		}
		b.WriteString(head + "\n    " + val + "\n")
	}
	b.WriteString("\n  " + fg(colMute, false).Render(hints) + "\n")
	return b.String()
}

func (m model) footerView() string {
	var live uint64
	for _, p := range m.profiles {
		if len(m.running[p.FolderName]) > 0 {
			live += m.rss[p.FolderName]
		}
	}
	cpu := "—"
	if m.cpuOK {
		cpu = fmt.Sprintf("%.0f%%", m.cpu)
	}
	total := "—"
	if m.totalMem > 0 {
		total = formatBytes(m.totalMem)
	}
	stats := fmt.Sprintf("CPU %s · RAM %s / %s · %d profiles",
		cpu, formatBytes(live), total, len(m.profiles))
	hints := "/ filter · enter launch · x stop · n new · d delete · R rescan · q quit"
	out := " " + fg(colDim, false).Render(stats) + "\n" +
		" " + fg(colMute, false).Render(hints)
	if m.status != "" && time.Since(m.statusAt) < 6*time.Second {
		out += "\n " + fg(colAmber, false).Render(m.status)
	}
	if m.confirmDelete != "" {
		out += "\n " + fg(colRed, true).Render("Press d again to confirm delete")
	}
	return out
}

func (m model) View() string {
	parts := []string{"", m.headerView(), m.filterView(), ""}
	if m.formActive {
		parts = append(parts, m.formView())
	} else {
		parts = append(parts, m.listView())
	}
	parts = append(parts, "", m.footerView(), "")
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}
