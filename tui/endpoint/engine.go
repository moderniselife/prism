package endpoint

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// LogEntry is one line in the recent-requests list (no message content).
type LogEntry struct {
	Date          time.Time `json:"date"`
	Client        string    `json:"client"`
	API           string    `json:"api"`
	Identity      string    `json:"identity"`
	IdentityColor string    `json:"identityColor"`
	Provider      string    `json:"provider"`
	Model         string    `json:"model"`
	Reason        string    `json:"reason"`
	Status        int       `json:"status"`
	Milliseconds  int       `json:"ms"`
	Stream        bool      `json:"stream"`
	InputTokens   int       `json:"inputTokens"`
	OutputTokens  int       `json:"outputTokens"`
	Cost          *float64  `json:"cost,omitempty"`
	Note          string    `json:"note,omitempty"`
	Error         string    `json:"error,omitempty"`
}

// Engine serves the endpoint. Safe for concurrent use.
type Engine struct {
	mu         sync.Mutex
	cfg        Config
	configPath string
	configMod  time.Time
	models     map[string]modelCache
	cooldowns  map[string]time.Time
	log        []LogEntry

	Keys    *Keys
	Usage   *UsageStore
	Client  *http.Client
	Version string
	// OnLog, if set, sees every entry (the TUI uses it).
	OnLog func(LogEntry)
}

type modelCache struct {
	at     time.Time
	models []string
}

// NewEngine reads the config at path (and keeps it fresh).
func NewEngine(path string) *Engine {
	dir := filepath.Dir(path)
	e := &Engine{
		configPath: path,
		models:     map[string]modelCache{},
		cooldowns:  map[string]time.Time{},
		Keys:       NewKeys(dir),
		Usage:      NewUsageStore(filepath.Join(dir, "endpoint-usage.json")),
		Client:     &http.Client{Timeout: 0, Transport: &http.Transport{Proxy: http.ProxyFromEnvironment, ResponseHeaderTimeout: 10 * time.Minute, MaxIdleConnsPerHost: 16}},
		Version:    "dev",
	}
	e.Reload()
	return e
}

// NewMemoryEngine runs from cfg with keys and usage kept in memory (tests).
func NewMemoryEngine(cfg Config) *Engine {
	e := &Engine{cfg: cfg, models: map[string]modelCache{}, cooldowns: map[string]time.Time{},
		Keys: &Keys{cache: map[string]string{}, Memory: true}, Usage: NewUsageStore(""),
		Client: &http.Client{}, Version: "test"}
	return e
}

func (e *Engine) Config() Config {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.cfg
}

func (e *Engine) SetConfig(c Config) {
	e.mu.Lock()
	e.cfg = c
	e.mu.Unlock()
}

// Reload re-reads the config file if it changed.
func (e *Engine) Reload() error {
	if e.configPath == "" {
		return nil
	}
	st, err := os.Stat(e.configPath)
	if err == nil && !st.ModTime().After(e.configMod) && e.configMod != (time.Time{}) {
		return nil
	}
	c, err := Load(e.configPath)
	if err != nil {
		return err
	}
	e.mu.Lock()
	e.cfg = c
	if st != nil {
		e.configMod = st.ModTime()
	}
	e.mu.Unlock()
	return nil
}

func (e *Engine) saveConfig(c Config) error {
	e.SetConfig(c)
	if e.configPath == "" {
		return nil
	}
	if err := Save(e.configPath, c); err != nil {
		return err
	}
	if st, err := os.Stat(e.configPath); err == nil {
		e.mu.Lock()
		e.configMod = st.ModTime()
		e.mu.Unlock()
	}
	return nil
}

func (e *Engine) Log() []LogEntry {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]LogEntry, len(e.log))
	copy(out, e.log)
	return out
}

func (e *Engine) addLog(l LogEntry) {
	e.mu.Lock()
	e.log = append([]LogEntry{l}, e.log...)
	if len(e.log) > 100 {
		e.log = e.log[:100]
	}
	cb := e.OnLog
	e.mu.Unlock()
	if cb != nil {
		cb(l)
	}
}

// --- Models -------------------------------------------------------------

func (e *Engine) KnownModels(c Credential) []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.models[c.ID].models
}

func (e *Engine) SetModels(id string, models []string) {
	e.mu.Lock()
	e.models[id] = modelCache{time.Now(), models}
	e.mu.Unlock()
}

func (e *Engine) stale(c Credential) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	m, ok := e.models[c.ID]
	return !ok || time.Since(m.at) > 10*time.Minute
}

// FetchModels asks the provider which models this key can use.
func (e *Engine) FetchModels(ctx context.Context, c Credential) ([]string, error) {
	base := c.EffectiveBaseURL()
	if base == "" {
		return nil, errors.New("enter the server's URL first")
	}
	u := base + "/models"
	if c.Provider == Anthropic {
		u = base + "/v1/models?limit=1000"
	}
	req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return nil, err
	}
	key := e.Keys.Get(c.ID)
	if c.Provider == Anthropic {
		req.Header.Set("x-api-key", key)
		req.Header.Set("anthropic-version", "2023-06-01")
	} else if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	resp, err := e.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("%s: %s (HTTP %d)", c.Provider.Label(), errorMessage(data), resp.StatusCode)
	}
	var ids []string
	for _, m := range jarr(parseJSON(data)["data"]) {
		if id := jstr(jobj(m)["id"]); id != "" {
			ids = append(ids, id)
		}
	}
	models := chatModels(ids, c.Provider)
	e.SetModels(c.ID, models)
	return models, nil
}

func (e *Engine) refreshStaleModels() {
	var wg sync.WaitGroup
	for _, id := range e.Config().Identities {
		for _, c := range id.Credentials {
			if !e.stale(c) || (c.Provider.KeyRequired() && e.Keys.Get(c.ID) == "") || (c.Provider == Compatible && c.BaseURL == "") {
				continue
			}
			wg.Add(1)
			go func(c Credential) {
				defer wg.Done()
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				defer cancel()
				if _, err := e.FetchModels(ctx, c); err != nil {
					e.SetModels(c.ID, e.KnownModels(c))
				}
			}(c)
		}
	}
	wg.Wait()
}

// --- Limits -------------------------------------------------------------

func cooldownKey(id string, p Provider) string { return id + "|" + string(p) }

func (e *Engine) CoolDown(identityID string, p Provider, d time.Duration) {
	e.mu.Lock()
	e.cooldowns[cooldownKey(identityID, p)] = time.Now().Add(d)
	e.mu.Unlock()
}

func (e *Engine) Cooldown(identityID string, p Provider) (time.Time, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	t, ok := e.cooldowns[cooldownKey(identityID, p)]
	return t, ok && t.After(time.Now())
}

// Cooldowns maps identity id → latest cooldown end.
func (e *Engine) Cooldowns() map[string]time.Time {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := map[string]time.Time{}
	now := time.Now()
	for k, t := range e.cooldowns {
		if t.After(now) {
			id := strings.SplitN(k, "|", 2)[0]
			if t.After(out[id]) {
				out[id] = t
			}
		}
	}
	return out
}

func (e *Engine) overBudget(id Identity) bool {
	return id.MonthlyBudget > 0 && e.Usage.Month(id.ID, time.Now()).Cost >= id.MonthlyBudget
}

func money(v float64) string {
	if v >= 100 {
		return strconv.FormatFloat(v, 'f', 0, 64)
	}
	return strconv.FormatFloat(v, 'f', 2, 64)
}

func (e *Engine) limitReason(r Route) string {
	if e.overBudget(r.Identity) && r.Identity.action() != BudgetWarn {
		return "is over its $" + money(r.Identity.MonthlyBudget) + " monthly budget"
	}
	if t, ok := e.Cooldown(r.Identity.ID, r.Credential.Provider); ok {
		return "is rate-limited until " + t.Format("15:04")
	}
	return ""
}

func (e *Engine) applyLimits(r Route, cfg Config, visited map[string]bool, notes *[]string) (Route, *RouteError) {
	for {
		reason := e.limitReason(r)
		if reason == "" {
			return r, nil
		}
		if fb := cfg.Identity(r.Identity.FallbackIdentityID); fb != nil && !visited[fb.ID] {
			if cred, ok := credentialFor(r.Model, *fb, e.KnownModels); ok {
				*notes = append(*notes, r.Identity.Name+" "+reason+" → "+fb.Name)
				visited[fb.ID] = true
				r = Route{Identity: *fb, Credential: cred, Model: r.Model, Reason: r.Reason}
				continue
			}
		}
		if e.overBudget(r.Identity) && r.Identity.action() != BudgetWarn {
			return r, &RouteError{429, r.Identity.Name + " " + reason + ". Raise the budget in Prism's Endpoint settings."}
		}
		return r, nil // rate-limited with nowhere to go: try anyway
	}
}

// limitCooldown: how long to avoid an account after this error, or 0 if
// the error isn't about the account's limits.
func limitCooldown(status int, data []byte, retryAfter string) time.Duration {
	m := strings.ToLower(errorMessage(data))
	credit := false
	for _, w := range []string{"credit", "billing", "quota", "insufficient", "balance", "payment"} {
		if strings.Contains(m, w) {
			credit = true
		}
	}
	if status == 402 || ((status == 400 || status == 403 || status == 429) && credit) {
		return 15 * time.Minute
	}
	if status == 429 {
		if s, err := strconv.ParseFloat(strings.TrimSpace(retryAfter), 64); err == nil {
			if s < 5 {
				s = 5
			}
			if s > 3600 {
				s = 3600
			}
			return time.Duration(s * float64(time.Second))
		}
		return time.Minute
	}
	return 0
}

// --- HTTP -------------------------------------------------------------------

func normalizePath(p string) string {
	for strings.HasPrefix(p, "/v1/v1/") {
		p = p[3:]
	}
	if len(p) > 1 {
		p = strings.TrimSuffix(p, "/")
	}
	if !strings.HasPrefix(p, "/v1/") && p != "/v1" && p != "/" && !strings.HasPrefix(p, "/prism/") {
		p = "/v1" + p
	}
	return p
}

func presentedToken(r *http.Request) string {
	t := r.Header.Get("x-api-key")
	if t == "" {
		t = r.Header.Get("api-key")
	}
	if a := r.Header.Get("Authorization"); strings.HasPrefix(strings.ToLower(a), "bearer ") {
		t = strings.TrimSpace(a[7:])
	}
	return t
}

func prefersAnthropic(r *http.Request) bool {
	return r.Header.Get("anthropic-version") != "" || r.Header.Get("x-api-key") != ""
}

func writeJSON(w http.ResponseWriter, status int, v any, headers ...[2]string) {
	for _, h := range headers {
		w.Header().Set(h[0], h[1])
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(toJSON(v))
}

func (e *Engine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Expose-Headers", "X-Prism-Identity, X-Prism-Upstream")
	if r.Method == "OPTIONS" {
		w.WriteHeader(204)
		return
	}
	path := normalizePath(r.URL.Path)
	if r.Method == "GET" && (path == "/" || path == "/v1" || path == "/v1/health") {
		writeJSON(w, 200, obj{"name": "Prism endpoint", "ok": true})
		return
	}
	cfg := e.Config()
	token := presentedToken(r)
	pinned := ""
	authorized := token != "" && token == cfg.Token
	for _, id := range cfg.Identities {
		if token != "" && token == id.Token {
			pinned, authorized = id.ID, true
		}
	}
	if strings.HasPrefix(path, "/prism/") {
		// Admin: main token only.
		if token == "" || token != cfg.Token {
			writeJSON(w, 401, obj{"error": "Use the endpoint's main token."})
			return
		}
		e.admin(w, r, path)
		return
	}
	if !authorized && (cfg.RequireToken || cfg.AllowLAN) {
		api := APIChat
		if prefersAnthropic(r) {
			api = APIAnthropic
		}
		writeJSON(w, 401, errorBody(api, 401, "Use your Prism endpoint token as the API key (Prism's Endpoint settings)."))
		return
	}
	switch {
	case r.Method == "GET" && path == "/v1/models":
		e.refreshStaleModels()
		lc := cfg
		if pinned != "" {
			lc.Identities = nil
			if id := cfg.Identity(pinned); id != nil {
				lc.Identities = []Identity{*id}
			}
			lc.ActiveIdentityID = pinned
		}
		writeJSON(w, 200, modelList(lc, e.KnownModels))
	case r.Method == "GET" && strings.HasPrefix(path, "/v1/models/"):
		id := strings.TrimPrefix(path, "/v1/models/")
		for _, m := range jarr(modelList(cfg, e.KnownModels)["data"]) {
			if jstr(jobj(m)["id"]) == id {
				writeJSON(w, 200, m)
				return
			}
		}
		api := APIChat
		if prefersAnthropic(r) {
			api = APIAnthropic
		}
		writeJSON(w, 404, errorBody(api, 404, "Unknown model "+id))
	case r.Method == "POST" && path == "/v1/messages":
		e.proxy(APIAnthropic, w, r, cfg, pinned)
	case r.Method == "POST" && path == "/v1/messages/count_tokens":
		e.countTokens(w, r, cfg, pinned)
	case r.Method == "POST" && path == "/v1/chat/completions":
		e.proxy(APIChat, w, r, cfg, pinned)
	case r.Method == "POST" && path == "/v1/responses":
		e.proxy(APIResponses, w, r, cfg, pinned)
	default:
		api := APIChat
		if prefersAnthropic(r) {
			api = APIAnthropic
		}
		writeJSON(w, 404, errorBody(api, 404, "Prism doesn't serve "+r.Method+" "+r.URL.Path))
	}
}

func clientName(r *http.Request) string {
	ua := strings.Fields(r.UserAgent())
	if len(ua) == 0 {
		return "unknown"
	}
	if len(ua[0]) > 40 {
		return ua[0][:40]
	}
	return ua[0]
}

type upstream struct {
	api         API
	body        obj
	passthrough bool
	canon       *canonRequest
}

func buildUpstream(api API, body obj, rt Route) (upstream, *RouteError) {
	p := rt.Credential.Provider
	upAPI := APIChat
	if p == Anthropic {
		upAPI = APIAnthropic
	} else if api == APIResponses && p == OpenAI {
		upAPI = APIResponses
	}
	if upAPI == api {
		b := cloneObj(body)
		b["model"] = rt.Model
		return upstream{api: api, body: b, passthrough: true}, nil
	}
	if prev, ok := body["previous_response_id"]; api == APIResponses && ok && prev != nil {
		return upstream{}, &RouteError{400, "previous_response_id only works with OpenAI accounts. Turn off server-side storage (store: false) in your client to use " + p.Label() + "."}
	}
	var c canonRequest
	switch api {
	case APIAnthropic:
		c = canonFromAnthropic(body)
	case APIChat:
		c = canonFromChat(body)
	default:
		c = canonFromResponses(body)
	}
	b := c.chatBody(rt.Model, p)
	if upAPI == APIAnthropic {
		b = c.anthropicBody(rt.Model)
	}
	return upstream{api: upAPI, body: b, canon: &c}, nil
}

// cloneObj deep-copies the body so stripping reasoning for one attempt
// doesn't change the original.
func cloneObj(o obj) obj { return parseJSON(toJSON(o)) }

func (e *Engine) proxy(api API, w http.ResponseWriter, r *http.Request, cfg Config, pinned string) {
	started := time.Now()
	raw, err := io.ReadAll(io.LimitReader(r.Body, 64<<20))
	body := parseJSON(raw)
	if err != nil || body == nil {
		writeJSON(w, 400, errorBody(api, 400, "Request body must be JSON."))
		return
	}
	requested := jstr(body["model"])
	stream, _ := jbool(body["stream"])
	var notes []string

	logIt := func(rt *Route, status int, u *Usage, errMsg string) {
		l := LogEntry{Date: started, Client: clientName(r), API: api.Label(), Identity: "—", IdentityColor: "#8E8E98", Provider: "—",
			Model: requested, Status: status, Milliseconds: int(time.Since(started).Milliseconds()), Stream: stream,
			Note: strings.Join(notes, "; "), Error: errMsg}
		if rt != nil {
			l.Identity, l.IdentityColor, l.Provider, l.Model, l.Reason = rt.Identity.Name, rt.Identity.ColorHex, rt.Credential.Provider.Label(), rt.Model, rt.Reason
			if u != nil {
				var cost *float64
				if p := PriceFor(rt.Model, rt.Credential.Provider, cfg.PriceOverrides); p != nil {
					c := p.Cost(*u)
					cost = &c
				}
				e.Usage.Record(rt.Identity.ID, rt.Model, *u, cost, started)
				l.InputTokens, l.OutputTokens, l.Cost = u.TotalInput(), u.Output, cost
			}
		}
		e.addLog(l)
	}

	rt, rerr := route(cfg, requested, userTexts(body, api), r.UserAgent(), time.Now(), pinned, e.KnownModels)
	if rerr != nil {
		writeJSON(w, rerr.Status, errorBody(api, rerr.Status, rerr.Message))
		logIt(nil, rerr.Status, nil, rerr.Message)
		return
	}
	if cfg.TagsEnabled {
		var slugs []string
		for _, id := range cfg.Identities {
			slugs = append(slugs, id.Slug())
		}
		stripTagsIn(body, slugs, api)
	}
	visited := map[string]bool{rt.Identity.ID: true}
	if rt, rerr = e.applyLimits(rt, cfg, visited, &notes); rerr != nil {
		writeJSON(w, rerr.Status, errorBody(api, rerr.Status, rerr.Message))
		logIt(&rt, rerr.Status, nil, rerr.Message)
		return
	}
	echoModel := requested
	if echoModel == "" {
		echoModel = rt.Model
	}
	strippedReasoning := false

	for attempt := 0; attempt < 2+len(cfg.Identities); attempt++ {
		cred := rt.Credential
		key := e.Keys.Get(cred.ID)
		if key == "" && cred.Provider.KeyRequired() {
			msg := "No " + cred.Provider.Label() + " key saved for " + rt.Identity.Name + ". Add it in Prism's Endpoint settings."
			writeJSON(w, 401, errorBody(api, 401, msg))
			logIt(&rt, 401, nil, msg)
			return
		}
		up, uerr := buildUpstream(api, body, rt)
		if uerr != nil {
			writeJSON(w, uerr.Status, errorBody(api, uerr.Status, uerr.Message))
			logIt(&rt, uerr.Status, nil, uerr.Message)
			return
		}
		if strippedReasoning {
			stripReasoning(up.body, up.api)
		}
		req, err := e.upstreamRequest(r, up, cred, key, stream)
		if err != nil {
			writeJSON(w, 500, errorBody(api, 500, "Invalid provider URL for "+rt.Identity.Name+"."))
			logIt(&rt, 500, nil, "invalid URL")
			return
		}
		resp, err := e.Client.Do(req)
		if err != nil {
			msg := "Couldn't reach " + cred.Provider.Label() + " for " + rt.Identity.Name + ": " + err.Error()
			writeJSON(w, 502, errorBody(api, 502, msg))
			logIt(&rt, 502, nil, msg)
			return
		}
		if resp.StatusCode >= 400 {
			data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
			if !strippedReasoning && resp.StatusCode == 400 && reasoningError(data) && stripReasoning(cloneObj(up.body), up.api) {
				strippedReasoning = true
				continue
			}
			if wait := limitCooldown(resp.StatusCode, data, resp.Header.Get("Retry-After")); wait > 0 {
				e.CoolDown(rt.Identity.ID, cred.Provider, wait)
				if fb := cfg.Identity(rt.Identity.FallbackIdentityID); fb != nil && !visited[fb.ID] {
					if fbCred, ok := credentialFor(rt.Model, *fb, e.KnownModels); ok {
						why := "out of credit"
						if resp.StatusCode == 429 {
							why = "rate-limited"
						}
						notes = append(notes, fmt.Sprintf("%s %s (%d) → %s", rt.Identity.Name, why, resp.StatusCode, fb.Name))
						visited[fb.ID] = true
						rt = Route{Identity: *fb, Credential: fbCred, Model: rt.Model, Reason: rt.Reason}
						continue
					}
				}
			}
			e.sendUpstreamError(w, api, up.api, resp.StatusCode, data, rt)
			logIt(&rt, resp.StatusCode, nil, errorMessage(data))
			return
		}
		w.Header().Set("X-Prism-Identity", rt.Identity.Name)
		w.Header().Set("X-Prism-Upstream", string(cred.Provider)+"/"+rt.Model)
		if stream {
			w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
			w.Header().Set("Cache-Control", "no-cache")
			w.Header().Set("X-Accel-Buffering", "no")
			w.WriteHeader(200)
			var u Usage
			if up.passthrough {
				u = pipe(resp.Body, up.api, w)
			} else {
				u = translate(resp.Body, up.api, api, echoModel, up.canon, body, w)
			}
			resp.Body.Close()
			logIt(&rt, 200, &u, "")
			return
		}
		data, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		j := parseJSON(data)
		if up.passthrough {
			ct := resp.Header.Get("Content-Type")
			if ct == "" {
				ct = "application/json"
			}
			w.Header().Set("Content-Type", ct)
			w.WriteHeader(200)
			_, _ = w.Write(data)
			var u *Usage
			if j != nil {
				x := usageFromReply(j, up.api)
				u = &x
			}
			logIt(&rt, 200, u, "")
			return
		}
		if j == nil {
			writeJSON(w, 502, errorBody(api, 502, "Provider sent an unreadable reply."))
			logIt(&rt, 502, nil, "unreadable reply")
			return
		}
		cr := responseFromChat(j)
		if up.api == APIAnthropic {
			cr = responseFromAnthropic(j)
		}
		now := time.Now().Unix()
		var out obj
		switch api {
		case APIAnthropic:
			out = cr.anthropicJSON(echoModel)
		case APIChat:
			out = cr.chatJSON(echoModel, now)
		default:
			out = cr.responsesJSON(echoModel, up.canon.customTools(), now)
		}
		writeJSON(w, 200, out)
		logIt(&rt, 200, &cr.usage, "")
		return
	}
	writeJSON(w, 502, errorBody(api, 502, "Every identity Prism tried was unavailable."))
	logIt(&rt, 502, nil, "no identity available")
}

func reasoningError(data []byte) bool {
	m := strings.ToLower(errorMessage(data))
	for _, w := range []string{"signature", "encrypted", "thinking", "reasoning"} {
		if strings.Contains(m, w) {
			return true
		}
	}
	return false
}

func (e *Engine) upstreamRequest(client *http.Request, up upstream, cred Credential, key string, stream bool) (*http.Request, error) {
	base := cred.EffectiveBaseURL()
	var u string
	switch up.api {
	case APIAnthropic:
		u = base + "/v1/messages"
		if up.passthrough && client.URL.RawQuery != "" {
			u += "?" + client.URL.RawQuery
		}
	case APIChat:
		u = base + "/chat/completions"
	default:
		u = base + "/responses"
	}
	req, err := http.NewRequestWithContext(client.Context(), "POST", u, bytes.NewReader(toJSON(up.body)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if stream {
		req.Header.Set("Accept", "text/event-stream")
	} else {
		req.Header.Set("Accept", "application/json")
	}
	req.Header.Set("User-Agent", "Prism/"+e.Version)
	if cred.Provider == Anthropic {
		req.Header.Set("x-api-key", key)
		v := "2023-06-01"
		if up.passthrough && client.Header.Get("anthropic-version") != "" {
			v = client.Header.Get("anthropic-version")
		}
		req.Header.Set("anthropic-version", v)
		if b := client.Header.Get("anthropic-beta"); up.passthrough && b != "" {
			req.Header.Set("anthropic-beta", b)
		}
	} else {
		if key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		if b := client.Header.Get("OpenAI-Beta"); up.passthrough && b != "" {
			req.Header.Set("OpenAI-Beta", b)
		}
	}
	return req, nil
}

func (e *Engine) sendUpstreamError(w http.ResponseWriter, api, upAPI API, status int, data []byte, rt Route) {
	w.Header().Set("X-Prism-Identity", rt.Identity.Name)
	if (api == APIAnthropic) == (upAPI == APIAnthropic) && parseJSON(data) != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write(data)
		return
	}
	msg := rt.Identity.Name + " · " + rt.Credential.Provider.Label() + ": " + errorMessage(data)
	writeJSON(w, status, errorBody(api, status, msg))
}

func flush(w http.ResponseWriter) {
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

func pipe(body io.Reader, api API, w http.ResponseWriter) Usage {
	s := &usageSniffer{api: api}
	rd := bufio.NewReaderSize(body, 64*1024)
	for {
		line, err := rd.ReadBytes('\n')
		if len(line) > 0 {
			s.feed(line)
			if _, werr := w.Write(line); werr != nil {
				return s.usage
			}
			flush(w)
		}
		if err != nil {
			return s.usage
		}
	}
}

func translate(body io.Reader, upAPI, api API, model string, canon *canonRequest, clientBody obj, w http.ResponseWriter) Usage {
	var dec streamDecoder = newChatDecoder()
	if upAPI == APIAnthropic {
		dec = newAnthropicDecoder()
	}
	var enc streamEncoder
	switch api {
	case APIAnthropic:
		enc = newAnthropicEncoder(model)
	case APIChat:
		inc, _ := jbool(jobj(clientBody["stream_options"])["include_usage"])
		enc = newChatEncoder(model, inc)
	default:
		custom := map[string]bool{}
		if canon != nil {
			custom = canon.customTools()
		}
		enc = newResponsesEncoder(model, custom)
	}
	var u Usage
	encode := func(evs []streamEvent) string {
		var b strings.Builder
		for _, ev := range evs {
			if ev.kind == evStart && ev.usage.TotalInput() > 0 {
				u = ev.usage
			}
			if ev.kind == evFinish {
				u = ev.usage
			}
			b.WriteString(enc.encode(ev))
		}
		return b.String()
	}
	write := func(s string) bool {
		if s == "" {
			return true
		}
		if _, err := io.WriteString(w, s); err != nil {
			return false
		}
		flush(w)
		return true
	}
	rd := bufio.NewReaderSize(body, 64*1024)
	for {
		line, err := rd.ReadString('\n')
		if p, ok := ssePayload(line); ok {
			if !write(encode(dec.decode(p))) {
				return u
			}
		}
		if err != nil {
			if err != io.EOF {
				write(enc.encode(streamEvent{kind: evError, text: "Connection to the provider dropped: " + err.Error()}))
				return u
			}
			break
		}
	}
	write(encode(dec.end()))
	return u
}

func (e *Engine) countTokens(w http.ResponseWriter, r *http.Request, cfg Config, pinned string) {
	raw, _ := io.ReadAll(io.LimitReader(r.Body, 64<<20))
	body := parseJSON(raw)
	if body == nil {
		writeJSON(w, 400, errorBody(APIAnthropic, 400, "Request body must be JSON."))
		return
	}
	n := len(raw) / 4
	if n < 1 {
		n = 1
	}
	estimate := obj{"input_tokens": n}
	rt, rerr := route(cfg, jstr(body["model"]), userTexts(body, APIAnthropic), r.UserAgent(), time.Now(), pinned, e.KnownModels)
	key := ""
	if rerr == nil {
		key = e.Keys.Get(rt.Credential.ID)
	}
	if rerr != nil || rt.Credential.Provider != Anthropic || key == "" {
		writeJSON(w, 200, estimate)
		return
	}
	body["model"] = rt.Model
	req, err := http.NewRequestWithContext(r.Context(), "POST", rt.Credential.EffectiveBaseURL()+"/v1/messages/count_tokens", bytes.NewReader(toJSON(body)))
	if err != nil {
		writeJSON(w, 200, estimate)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", key)
	v := r.Header.Get("anthropic-version")
	if v == "" {
		v = "2023-06-01"
	}
	req.Header.Set("anthropic-version", v)
	if b := r.Header.Get("anthropic-beta"); b != "" {
		req.Header.Set("anthropic-beta", b)
	}
	resp, err := e.Client.Do(req)
	if err != nil {
		writeJSON(w, 200, estimate)
		return
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		writeJSON(w, 200, estimate)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(data)
}

// --- Admin API (for Prism's Windows/Linux apps and the TUI) ---------------

// IdentityStatus is what the apps show per identity.
type IdentityStatus struct {
	ID            string          `json:"id"`
	Name          string          `json:"name"`
	Slug          string          `json:"slug"`
	ColorHex      string          `json:"colorHex"`
	Active        bool            `json:"active"`
	Keys          map[string]bool `json:"keys"`
	MonthCost     float64         `json:"monthCost"`
	MonthRequests int             `json:"monthRequests"`
	MonthTokens   int             `json:"monthTokens"`
	TodayCost     float64         `json:"todayCost"`
	Budget        float64         `json:"budget,omitempty"`
	CooldownUntil *time.Time      `json:"cooldownUntil,omitempty"`
	Models        []string        `json:"models"`
	TopModels     []ModelTotals   `json:"topModels"`
}

type Status struct {
	Version        string           `json:"version"`
	Port           int              `json:"port"`
	ConfigPath     string           `json:"configPath"`
	KeysInFile     bool             `json:"keysInFile"`
	Identities     []IdentityStatus `json:"identities"`
	Log            []LogEntry       `json:"log"`
	UnpricedModels []string         `json:"unpricedModels"`
}

func (e *Engine) Status() Status {
	cfg := e.Config()
	now := time.Now()
	cool := e.Cooldowns()
	st := Status{Version: e.Version, Port: cfg.Port, ConfigPath: e.configPath, Log: e.Log(), UnpricedModels: e.Usage.UnpricedModels(now)}
	active := cfg.Active()
	for _, id := range cfg.Identities {
		m := e.Usage.Month(id.ID, now)
		s := IdentityStatus{ID: id.ID, Name: id.Name, Slug: id.Slug(), ColorHex: id.ColorHex, Active: active != nil && active.ID == id.ID,
			Keys: map[string]bool{}, MonthCost: m.Cost, MonthRequests: m.Requests, MonthTokens: m.Tokens(),
			TodayCost: e.Usage.Day(id.ID, now).Cost, Budget: id.MonthlyBudget, Models: []string{}}
		for _, c := range id.Credentials {
			s.Keys[c.ID] = e.Keys.Has(c.ID)
			s.Models = append(s.Models, e.KnownModels(c)...)
		}
		if t, ok := cool[id.ID]; ok {
			t := t
			s.CooldownUntil = &t
		}
		top := e.Usage.MonthByModel(id.ID, now)
		if len(top) > 8 {
			top = top[:8]
		}
		s.TopModels = top
		st.Identities = append(st.Identities, s)
	}
	st.KeysInFile = e.Keys.UsingFile
	if st.Log == nil {
		st.Log = []LogEntry{}
	}
	return st
}

// SetActive switches the active identity and saves the config.
func (e *Engine) SetActive(id string) error {
	c := e.Config()
	if c.Identity(id) == nil {
		return errors.New("no such identity")
	}
	c.ActiveIdentityID = id
	return e.saveConfig(c)
}

func (e *Engine) admin(w http.ResponseWriter, r *http.Request, path string) {
	var in obj
	if r.Method == "POST" {
		raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		in = parseJSON(raw)
		if in == nil {
			in = obj{}
		}
	}
	switch path {
	case "/prism/status":
		_ = e.Reload()
		writeJSON(w, 200, e.Status())
	case "/prism/reload":
		e.mu.Lock()
		e.configMod = time.Time{}
		e.mu.Unlock()
		if err := e.Reload(); err != nil {
			writeJSON(w, 500, obj{"error": err.Error()})
			return
		}
		writeJSON(w, 200, obj{"ok": true})
	case "/prism/active":
		if err := e.SetActive(jstr(in["identityID"])); err != nil {
			writeJSON(w, 400, obj{"error": err.Error()})
			return
		}
		writeJSON(w, 200, obj{"ok": true})
	case "/prism/key":
		if err := e.Keys.Set(jstr(in["credentialID"]), strings.TrimSpace(jstr(in["key"]))); err != nil {
			writeJSON(w, 500, obj{"error": err.Error()})
			return
		}
		writeJSON(w, 200, obj{"ok": true, "keysInFile": e.Keys.UsingFile})
	case "/prism/check":
		var cred *Credential
		for _, id := range e.Config().Identities {
			for i := range id.Credentials {
				if id.Credentials[i].ID == jstr(in["credentialID"]) {
					cred = &id.Credentials[i]
				}
			}
		}
		if cred == nil {
			writeJSON(w, 404, obj{"error": "Save the identity first."})
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		models, err := e.FetchModels(ctx, *cred)
		if err != nil {
			writeJSON(w, 200, obj{"ok": false, "error": err.Error()})
			return
		}
		if models == nil {
			models = []string{}
		}
		writeJSON(w, 200, obj{"ok": true, "models": models})
	case "/prism/stop":
		writeJSON(w, 200, obj{"ok": true})
		go func() {
			time.Sleep(200 * time.Millisecond)
			e.Usage.Save()
			os.Exit(0)
		}()
	default:
		writeJSON(w, 404, obj{"error": "unknown admin path"})
	}
}

// --- Serving ------------------------------------------------------------------

// Serve runs the endpoint until ctx ends, re-reading the config file every
// few seconds (the apps edit it directly).
func (e *Engine) Serve(ctx context.Context) error {
	cfg := e.Config()
	host := "127.0.0.1"
	if cfg.AllowLAN {
		host = "0.0.0.0"
	}
	ln, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(cfg.Port)))
	if err != nil {
		return fmt.Errorf("port %d: %w", cfg.Port, err)
	}
	srv := &http.Server{Handler: e, ReadHeaderTimeout: 30 * time.Second}
	go func() {
		t := time.NewTicker(3 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				_ = e.Reload()
			}
		}
	}()
	go func() {
		<-ctx.Done()
		e.Usage.Save()
		sctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()
	err = srv.Serve(ln)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
