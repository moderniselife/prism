package endpoint

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Spend per identity, priced from a list you can edit. Estimates: list
// prices before discounts, surcharges or tool fees.

func (p Price) Cost(u Usage) float64 {
	return (float64(u.Input)*p.Input + float64(u.Output)*p.Output +
		float64(u.CacheRead)*p.CacheRead + float64(u.CacheWrite)*p.CacheWrite) / 1_000_000
}

// BuiltInPrices: published list prices (Nov 2026), per million tokens,
// matched by the longest model-id prefix. Same table as the macOS app.
var BuiltInPrices = func() map[string]Price {
	t := map[string]Price{}
	a := func(id string, in, out, cr float64) { t[id] = Price{in, out, cr, in * 1.25} }
	o := func(id string, in, out, cr float64) {
		if cr == 0 {
			cr = in
		}
		t[id] = Price{in, out, cr, in}
	}
	a("claude-opus-5-5", 4, 20, 0.20)
	a("claude-sonnet-5-5", 2, 10, 0.10)
	a("claude-haiku-5-5", 0.10, 0.50, 0.01)
	a("claude-fable-5-2", 8, 40, 0.20)
	a("claude-fable-5-1", 10, 50, 0.25)
	a("claude-mythos-5-2", 8, 40, 0.20)
	a("claude-mythos-5", 10, 50, 1)
	a("claude-opus-5", 5, 25, 0.50)
	a("claude-sonnet-5", 2, 10, 0.20)
	a("claude-haiku-4-5", 1, 5, 0.10)
	a("claude-opus-4-1", 15, 75, 1.50)
	a("claude-opus-4-2025", 15, 75, 1.50)
	a("claude-opus-4", 5, 25, 0.50)
	a("claude-sonnet-4", 3, 15, 0.30)
	a("claude-3-7-sonnet", 3, 15, 0.30)
	a("claude-3-5-sonnet", 3, 15, 0.30)
	a("claude-3-5-haiku", 0.80, 4, 0.08)
	a("claude-3-haiku", 0.25, 1.25, 0.03)
	o("gpt-6-astra", 10, 50, 1)
	o("gpt-6.1-sol", 2, 10, 0.10)
	o("gpt-6.1-terra", 1, 5, 0.05)
	o("gpt-6-luna", 0.10, 0.50, 0.01)
	o("gpt-6-sol", 2, 10, 0.20)
	o("gpt-5.6-sol", 4, 20, 0.40)
	o("gpt-5.6-terra", 2, 12, 0.20)
	o("gpt-5.6-luna", 0.20, 1.20, 0.02)
	o("gpt-5.5-pro", 30, 180, 0)
	o("gpt-5.5", 5, 30, 0.50)
	o("gpt-5.4-pro", 30, 180, 0)
	o("gpt-5.4-mini", 0.75, 4.50, 0.075)
	o("gpt-5.4-nano", 0.20, 1.25, 0.02)
	o("gpt-5.4", 2.50, 15, 0.25)
	o("gpt-5.2-pro", 21, 168, 0)
	o("gpt-5.2", 1.75, 14, 0.175)
	o("gpt-5.1", 1.25, 10, 0.125)
	o("gpt-5-pro", 15, 120, 0)
	o("gpt-5-mini", 0.25, 2, 0.025)
	o("gpt-5-nano", 0.05, 0.40, 0.005)
	o("gpt-5", 1.25, 10, 0.125)
	o("gpt-4.1-mini", 0.40, 1.60, 0.10)
	o("gpt-4.1", 2, 8, 0.50)
	o("gpt-4o-mini", 0.15, 0.60, 0.075)
	o("gpt-4o", 2.50, 10, 1.25)
	o("o3-pro", 20, 80, 0)
	o("o3", 2, 8, 0.50)
	return t
}()

// PriceFor is nil for unknown models; local servers are free unless priced.
func PriceFor(model string, p Provider, overrides map[string]Price) *Price {
	m := strings.ToLower(model)
	best := func(table map[string]Price) *Price {
		bestKey := ""
		for k := range table {
			if strings.HasPrefix(m, strings.ToLower(k)) && len(k) > len(bestKey) {
				bestKey = k
			}
		}
		if bestKey == "" {
			return nil
		}
		v := table[bestKey]
		return &v
	}
	if v := best(overrides); v != nil {
		return v
	}
	if p == Compatible {
		return &Price{}
	}
	return best(BuiltInPrices)
}

// Totals uses the macOS app's JSON keys.
type Totals struct {
	Requests   int     `json:"requests"`
	Input      int     `json:"input"`
	Output     int     `json:"output"`
	CacheRead  int     `json:"cacheRead"`
	CacheWrite int     `json:"cacheWrite"`
	Cost       float64 `json:"cost"`
	Unpriced   int     `json:"unpriced"`
}

func (t *Totals) add(o Totals) {
	t.Requests += o.Requests
	t.Input += o.Input
	t.Output += o.Output
	t.CacheRead += o.CacheRead
	t.CacheWrite += o.CacheWrite
	t.Cost += o.Cost
	t.Unpriced += o.Unpriced
}

func (t Totals) Tokens() int { return t.Input + t.Output + t.CacheRead + t.CacheWrite }

// UsageStore: day → identity id → model → totals, kept 120 days.
type UsageStore struct {
	mu    sync.Mutex
	days  map[string]map[string]map[string]Totals
	path  string
	dirty bool
	timer *time.Timer
}

func NewUsageStore(path string) *UsageStore {
	s := &UsageStore{days: map[string]map[string]map[string]Totals{}, path: path}
	if path != "" {
		if data, err := os.ReadFile(path); err == nil {
			_ = json.Unmarshal(data, &s.days)
		}
	}
	return s
}

func dayKey(t time.Time) string   { return t.Format("2006-01-02") }
func monthKey(t time.Time) string { return t.Format("2006-01") }

func (s *UsageStore) Record(identityID, model string, u Usage, cost *float64, at time.Time) {
	t := Totals{Requests: 1, Input: u.Input, Output: u.Output, CacheRead: u.CacheRead, CacheWrite: u.CacheWrite}
	if cost != nil {
		t.Cost = *cost
	} else if u.Input+u.Output > 0 {
		t.Unpriced = 1
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	d := dayKey(at)
	if s.days[d] == nil {
		s.days[d] = map[string]map[string]Totals{}
	}
	if s.days[d][identityID] == nil {
		s.days[d][identityID] = map[string]Totals{}
	}
	cur := s.days[d][identityID][model]
	cur.add(t)
	s.days[d][identityID][model] = cur
	s.dirty = true
	if s.path != "" && s.timer == nil {
		s.timer = time.AfterFunc(3*time.Second, s.Save)
	}
}

func (s *UsageStore) Save() {
	s.mu.Lock()
	s.timer = nil
	if !s.dirty || s.path == "" {
		s.mu.Unlock()
		return
	}
	cutoff := dayKey(time.Now().AddDate(0, 0, -120))
	for d := range s.days {
		if d < cutoff {
			delete(s.days, d)
		}
	}
	data, err := json.Marshal(s.days)
	s.dirty = false
	path := s.path
	s.mu.Unlock()
	if err == nil {
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
		_ = os.WriteFile(path, data, 0o600)
	}
}

func (s *UsageStore) Month(identityID string, at time.Time) Totals {
	prefix := monthKey(at)
	s.mu.Lock()
	defer s.mu.Unlock()
	var t Totals
	for d, ids := range s.days {
		if strings.HasPrefix(d, prefix) {
			for _, v := range ids[identityID] {
				t.add(v)
			}
		}
	}
	return t
}

func (s *UsageStore) Day(identityID string, at time.Time) Totals {
	s.mu.Lock()
	defer s.mu.Unlock()
	var t Totals
	for _, v := range s.days[dayKey(at)][identityID] {
		t.add(v)
	}
	return t
}

type ModelTotals struct {
	Model  string `json:"model"`
	Totals Totals `json:"totals"`
}

func (s *UsageStore) MonthByModel(identityID string, at time.Time) []ModelTotals {
	prefix := monthKey(at)
	s.mu.Lock()
	m := map[string]Totals{}
	for d, ids := range s.days {
		if strings.HasPrefix(d, prefix) {
			for model, v := range ids[identityID] {
				cur := m[model]
				cur.add(v)
				m[model] = cur
			}
		}
	}
	s.mu.Unlock()
	var out []ModelTotals
	for k, v := range m {
		out = append(out, ModelTotals{k, v})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Totals.Cost == out[j].Totals.Cost {
			return out[i].Totals.Tokens() > out[j].Totals.Tokens()
		}
		return out[i].Totals.Cost > out[j].Totals.Cost
	})
	return out
}

func (s *UsageStore) UnpricedModels(at time.Time) []string {
	prefix := monthKey(at)
	s.mu.Lock()
	defer s.mu.Unlock()
	set := map[string]bool{}
	for d, ids := range s.days {
		if strings.HasPrefix(d, prefix) {
			for _, models := range ids {
				for m, t := range models {
					if t.Unpriced > 0 {
						set[m] = true
					}
				}
			}
		}
	}
	var out []string
	for m := range set {
		out = append(out, m)
	}
	sort.Strings(out)
	return out
}

// usageSniffer reads token counts from a stream being passed through.
type usageSniffer struct {
	api   API
	usage Usage
}

func (s *usageSniffer) feed(line []byte) {
	if len(line) < 7 || !bytes.Contains(line, []byte("usage")) {
		return
	}
	payload, ok := ssePayload(string(line))
	if !ok {
		return
	}
	j := parseJSON([]byte(payload))
	if j == nil {
		return
	}
	switch s.api {
	case APIAnthropic:
		if m := jobj(j["message"]); m != nil && jobj(m["usage"]) != nil {
			start := usageFromAnthropic(jobj(m["usage"]))
			s.usage.Input, s.usage.CacheRead, s.usage.CacheWrite = start.Input, start.CacheRead, start.CacheWrite
			if start.Output > 0 {
				s.usage.Output = start.Output
			}
		} else if u := jobj(j["usage"]); u != nil {
			if o, ok := jint(u["output_tokens"]); ok {
				s.usage.Output = o
			}
			if i, ok := jint(u["input_tokens"]); ok && i > 0 {
				s.usage.Input = i
			}
			if r, ok := jint(u["cache_read_input_tokens"]); ok && r > 0 {
				s.usage.CacheRead = r
			}
			if w, ok := jint(u["cache_creation_input_tokens"]); ok && w > 0 {
				s.usage.CacheWrite = w
			}
		}
	case APIChat:
		if u := jobj(j["usage"]); u != nil {
			s.usage = usageFromChat(u)
		}
	case APIResponses:
		if u := jobj(jobj(j["response"])["usage"]); u != nil {
			s.usage = usageFromResponses(u)
		}
	}
}
