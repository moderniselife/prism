package endpoint

import (
	"bufio"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// --- Mock provider ----------------------------------------------------------

type mockLog struct {
	mu   sync.Mutex
	last map[string]obj
}

func (m *mockLog) set(path string, b obj) { m.mu.Lock(); m.last[path] = b; m.mu.Unlock() }
func (m *mockLog) get(path string) obj    { m.mu.Lock(); defer m.mu.Unlock(); return m.last[path] }

func lastUser(b obj, api API) string {
	t := userTexts(b, api)
	if len(t) == 0 {
		return ""
	}
	return t[len(t)-1]
}

func mockProvider(t *testing.T, ml *mockLog) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		body := parseJSON(raw)
		ml.set(r.URL.Path, body)
		stream, _ := jbool(body["stream"])
		hasTools := len(jarr(body["tools"])) > 0
		switch {
		case strings.HasSuffix(r.URL.Path, "/models"):
			if strings.HasPrefix(r.URL.Path, "/anthropic") {
				writeJSON(w, 200, obj{"data": []any{obj{"id": "claude-test-sonnet"}}})
			} else {
				writeJSON(w, 200, obj{"data": []any{obj{"id": "gpt-test"}, obj{"id": "text-embedding-3-small"}}})
			}
		case r.URL.Path == "/anthropic/v1/messages":
			key := r.Header.Get("x-api-key")
			said := lastUser(body, APIAnthropic)
			if key == "ak-work" && strings.Contains(said, "ratelimit") {
				w.Header().Set("Retry-After", "30")
				writeJSON(w, 429, obj{"type": "error", "error": obj{"type": "rate_limit_error", "message": "Number of requests exceeded"}})
				return
			}
			for _, mv := range jarr(body["messages"]) {
				for _, b := range jarr(jobj(mv)["content"]) {
					if jstr(jobj(b)["type"]) == "thinking" {
						writeJSON(w, 400, obj{"type": "error", "error": obj{"type": "invalid_request_error", "message": "Invalid `signature` in `thinking` block"}})
						return
					}
				}
			}
			text := "key=" + key + " said=" + said
			if !stream {
				content := []any{obj{"type": "text", "text": text}}
				stop := "end_turn"
				if hasTools {
					content = append(content, obj{"type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": obj{"city": "Sydney"}})
					stop = "tool_use"
				}
				writeJSON(w, 200, obj{"id": "msg_1", "type": "message", "role": "assistant", "model": body["model"], "content": content,
					"stop_reason": stop, "usage": obj{"input_tokens": 11, "output_tokens": 7}})
				return
			}
			w.Header().Set("Content-Type", "text/event-stream")
			ev := func(name string, d obj) { fmt.Fprint(w, sseEvent(name, d)); flush(w) }
			ev("message_start", obj{"type": "message_start", "message": obj{"id": "msg_1", "type": "message", "role": "assistant", "model": body["model"], "content": []any{},
				"usage": obj{"input_tokens": 11, "output_tokens": 0}}})
			ev("content_block_start", obj{"type": "content_block_start", "index": 0, "content_block": obj{"type": "text", "text": ""}})
			ev("content_block_delta", obj{"type": "content_block_delta", "index": 0, "delta": obj{"type": "text_delta", "text": text}})
			ev("content_block_stop", obj{"type": "content_block_stop", "index": 0})
			stop := "end_turn"
			if hasTools {
				stop = "tool_use"
				ev("content_block_start", obj{"type": "content_block_start", "index": 1, "content_block": obj{"type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": obj{}}})
				ev("content_block_delta", obj{"type": "content_block_delta", "index": 1, "delta": obj{"type": "input_json_delta", "partial_json": `{"city":`}})
				ev("content_block_delta", obj{"type": "content_block_delta", "index": 1, "delta": obj{"type": "input_json_delta", "partial_json": `"Sydney"}`}})
				ev("content_block_stop", obj{"type": "content_block_stop", "index": 1})
			}
			ev("message_delta", obj{"type": "message_delta", "delta": obj{"stop_reason": stop}, "usage": obj{"output_tokens": 7}})
			ev("message_stop", obj{"type": "message_stop"})
		case r.URL.Path == "/openai/v1/chat/completions":
			key := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			text := "key=" + key + " said=" + lastUser(body, APIChat)
			if !stream {
				msg := obj{"role": "assistant", "content": text}
				fin := "stop"
				if hasTools {
					msg["tool_calls"] = []any{obj{"id": "call_1", "type": "function", "function": obj{"name": "get_weather", "arguments": `{"city":"Sydney"}`}}}
					fin = "tool_calls"
				}
				writeJSON(w, 200, obj{"id": "c1", "object": "chat.completion", "model": body["model"], "choices": []any{obj{"index": 0, "message": msg, "finish_reason": fin}},
					"usage": obj{"prompt_tokens": 20, "completion_tokens": 5}})
				return
			}
			w.Header().Set("Content-Type", "text/event-stream")
			chunk := func(delta obj, fin any) {
				fmt.Fprint(w, "data: "+string(toJSON(obj{"id": "c1", "model": body["model"], "choices": []any{obj{"index": 0, "delta": delta, "finish_reason": fin}}}))+"\n\n")
				flush(w)
			}
			chunk(obj{"role": "assistant", "content": ""}, nil)
			chunk(obj{"content": text}, nil)
			fin := "stop"
			if hasTools {
				chunk(obj{"tool_calls": []any{obj{"index": 0, "id": "call_1", "type": "function", "function": obj{"name": "get_weather", "arguments": ""}}}}, nil)
				chunk(obj{"tool_calls": []any{obj{"index": 0, "function": obj{"arguments": `{"city":"Sydney"}`}}}}, nil)
				fin = "tool_calls"
			}
			chunk(obj{}, fin)
			fmt.Fprint(w, "data: "+string(toJSON(obj{"id": "c1", "choices": []any{}, "usage": obj{"prompt_tokens": 20, "completion_tokens": 5}}))+"\n\n")
			fmt.Fprint(w, "data: [DONE]\n\n")
		case r.URL.Path == "/openai/v1/responses":
			key := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			for _, it := range jarr(body["input"]) {
				if jstr(jobj(it)["type"]) == "reasoning" && key == "ok-personal" {
					writeJSON(w, 400, obj{"error": obj{"message": "The encrypted content could not be verified.", "type": "invalid_request_error"}})
					return
				}
			}
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, `event: response.completed`+"\n"+`data: {"type":"response.completed","response":{"id":"resp_up","status":"completed","output":[],"note":"key=`+key+`","usage":{"input_tokens":30,"output_tokens":4}}}`+"\n\n")
		default:
			writeJSON(w, 404, obj{"error": obj{"message": "mock: no route " + r.URL.Path}})
		}
	}))
}

// --- Fixtures -------------------------------------------------------------------

func sampleConfig(base string) Config {
	c := Defaults()
	c.Enabled = true
	c.Token = "prism-test-token"
	c.Identities = []Identity{
		{ID: "work-id", Name: "Work", ColorHex: "#3B82F6", DefaultModel: "claude-test-sonnet", Token: "prism-work-token",
			Credentials: []Credential{{ID: "work-anthropic", Provider: Anthropic, BaseURL: base + "/anthropic"}, {ID: "work-openai", Provider: OpenAI, BaseURL: base + "/openai/v1"}}},
		{ID: "personal-id", Name: "Personal", ColorHex: "#F43F5E", DefaultModel: "gpt-test", Token: "prism-personal-token",
			Credentials: []Credential{{ID: "personal-anthropic", Provider: Anthropic, BaseURL: base + "/anthropic"}, {ID: "personal-openai", Provider: OpenAI, BaseURL: base + "/openai/v1"}}},
	}
	c.ActiveIdentityID = "personal-id"
	c.Rules = []Rule{
		{ID: "r1", Enabled: true, Kind: RuleKeyword, Pattern: "invoice, standup", IdentityID: "work-id"},
		{ID: "r2", Enabled: true, Kind: RuleClient, Pattern: "codex", IdentityID: "work-id"},
	}
	return c
}

type reply struct {
	status  int
	headers http.Header
	body    string
}

func (r reply) json() obj { return parseJSON([]byte(r.body)) }

func call(t *testing.T, url, method, path string, body any, token string, anthropicStyle bool, ua string) reply {
	t.Helper()
	var rd io.Reader
	if body != nil {
		rd = strings.NewReader(string(toJSON(body)))
	}
	req, _ := http.NewRequest(method, url+path, rd)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		if anthropicStyle {
			req.Header.Set("x-api-key", token)
			req.Header.Set("anthropic-version", "2023-06-01")
		} else {
			req.Header.Set("Authorization", "Bearer "+token)
		}
	}
	if ua == "" {
		ua = "test-client/1.0"
	}
	req.Header.Set("User-Agent", ua)
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return reply{resp.StatusCode, resp.Header, string(data)}
}

func payloads(body string) []obj {
	var out []obj
	sc := bufio.NewScanner(strings.NewReader(body))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		if p, ok := ssePayload(sc.Text()); ok {
			if j := parseJSON([]byte(p)); j != nil {
				out = append(out, j)
			}
		}
	}
	return out
}

func setup(t *testing.T) (*Engine, string, *mockLog) {
	ml := &mockLog{last: map[string]obj{}}
	mock := mockProvider(t, ml)
	t.Cleanup(mock.Close)
	e := NewMemoryEngine(sampleConfig(mock.URL))
	for id, k := range map[string]string{"work-anthropic": "ak-work", "work-openai": "ok-work", "personal-anthropic": "ak-personal", "personal-openai": "ok-personal"} {
		_ = e.Keys.Set(id, k)
	}
	srv := httptest.NewServer(e)
	t.Cleanup(srv.Close)
	return e, srv.URL, ml
}

// --- Unit -------------------------------------------------------------------------

func TestRouting(t *testing.T) {
	cfg := sampleConfig("http://x")
	none := func(Credential) []string { return nil }
	r := func(model string, texts []string, client, pinned string) Route {
		rt, err := route(cfg, model, texts, client, time.Now(), pinned, none)
		if err != nil {
			t.Fatalf("route %q: %v", model, err.Message)
		}
		return rt
	}
	cases := []struct {
		name, want string
		got        string
	}{
		{"prefix", "Work", r("work/claude-x", []string{"hi"}, "", "").Identity.Name},
		{"prefix strips", "claude-x", r("work/claude-x", []string{"hi"}, "", "").Model},
		{"bare identity → default", "claude-test-sonnet", r("work", []string{"hi"}, "", "").Model},
		{"follows active", "Personal", r("claude-x", []string{"hi"}, "", "").Identity.Name},
		{"tag", "Work", r("claude-x", []string{"@work hi"}, "", "").Identity.Name},
		{"tag sticks", "Work", r("claude-x", []string{"@work first", "then"}, "", "").Identity.Name},
		{"latest tag wins", "Personal", r("claude-x", []string{"@work first", "@personal now"}, "", "").Identity.Name},
		{"email not a tag", "Personal", r("claude-x", []string{"mail bob@work.com"}, "", "").Identity.Name},
		{"keyword rule", "Work", r("claude-x", []string{"draft the invoice please"}, "", "").Identity.Name},
		{"whole words", "Personal", r("claude-x", []string{"invoices"}, "", "").Identity.Name},
		{"client rule", "Work", r("gpt-5", []string{"hi"}, "codex_cli_rs/0.9", "").Identity.Name},
		{"pinned token", "Work", r("claude-x", []string{"hi"}, "", "work-id").Identity.Name},
		{"tag beats pinned", "Personal", r("claude-x", []string{"@personal hi"}, "", "work-id").Identity.Name},
		{"claude → anthropic", "anthropic", string(r("claude-x", []string{"hi"}, "", "").Credential.Provider)},
		{"gpt → openai", "openai", string(r("gpt-5", []string{"hi"}, "", "").Credential.Provider)},
		{"prism → default", "gpt-test", r("prism", []string{"hi"}, "", "").Model},
		{"strip tag", "draft this", StripTags([]string{"work"}, "@work  draft this")},
		{"strip keeps email", "email bob@work.com", StripTags([]string{"work"}, "email bob@work.com")},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s: got %q want %q", c.name, c.got, c.want)
		}
	}
	night := Rule{Kind: RuleSchedule, Days: []int{1, 2, 3, 4, 5, 6, 7}, StartMinute: 22 * 60, EndMinute: 6 * 60}
	if !ruleMatches(night, "", "", time.Date(2026, 11, 16, 23, 30, 0, 0, time.Local)) || ruleMatches(night, "", "", time.Date(2026, 11, 16, 12, 0, 0, 0, time.Local)) {
		t.Error("overnight schedule")
	}
}

func TestTranslation(t *testing.T) {
	chat := parseJSON([]byte(`{"model":"x","stream":true,"max_tokens":100,"temperature":1.5,"messages":[
	 {"role":"system","content":"be brief"},
	 {"role":"user","content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,AAAA"}}]},
	 {"role":"assistant","content":null,"tool_calls":[{"id":"call.1","type":"function","function":{"name":"f","arguments":"{\"a\":1}"}}]},
	 {"role":"tool","tool_call_id":"call.1","content":"42"},
	 {"role":"user","content":"thanks"}],
	 "tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}],"tool_choice":"required"}`))
	a := canonFromChat(chat).anthropicBody("claude-x")
	msgs := jarr(a["messages"])
	if a["system"] != "be brief" || len(msgs) != 3 {
		t.Fatalf("chat → anthropic shape: %s", toJSON(a))
	}
	tu := jobj(jarr(jobj(msgs[1])["content"])[0])
	if tu["type"] != "tool_use" || tu["id"] != "call_1" {
		t.Errorf("tool_use: %v", tu)
	}
	last := jarr(jobj(msgs[2])["content"])
	if jobj(last[0])["type"] != "tool_result" || jobj(last[1])["text"] != "thanks" {
		t.Errorf("tool_result leads: %v", last)
	}
	if a["temperature"] != 1.0 || jobj(a["tool_choice"])["type"] != "any" {
		t.Errorf("temperature/tool_choice: %v %v", a["temperature"], a["tool_choice"])
	}

	anth := parseJSON([]byte(`{"model":"x","max_tokens":50,"system":[{"type":"text","text":"sys"}],"messages":[
	 {"role":"user","content":"hi"},
	 {"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"s"},{"type":"text","text":"calling"},{"type":"tool_use","id":"toolu_9","name":"f","input":{"a":1}}]},
	 {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","content":[{"type":"text","text":"ok"}]}]}],
	 "tools":[{"name":"f","input_schema":{"type":"object"}},{"type":"web_search_20250305","name":"web_search"}]}`))
	c := canonFromAnthropic(anth).chatBody("gpt-x", OpenAI)
	var roles []string
	for _, m := range jarr(c["messages"]) {
		roles = append(roles, jstr(jobj(m)["role"]))
	}
	if strings.Join(roles, ",") != "system,user,assistant,tool" || len(jarr(c["tools"])) != 1 || c["max_completion_tokens"] != 50 {
		t.Errorf("anthropic → chat: %s", toJSON(c))
	}

	resp := parseJSON([]byte(`{"model":"x","instructions":"inst","input":[
	 {"type":"message","role":"developer","content":"dev note"},
	 {"type":"message","role":"user","content":[{"type":"input_text","text":"run ls"}]},
	 {"type":"reasoning","encrypted_content":"zzz"},
	 {"type":"function_call","call_id":"call_a","name":"shell","arguments":"{\"cmd\":\"ls\"}"},
	 {"type":"function_call_output","call_id":"call_a","output":"file.txt"},
	 {"type":"custom_tool_call","call_id":"call_b","name":"apply_patch","input":"*** Begin Patch"},
	 {"type":"custom_tool_call_output","call_id":"call_b","output":"done"}],
	 "tools":[{"type":"function","name":"shell","parameters":{"type":"object"}},{"type":"custom","name":"apply_patch"},{"type":"web_search"}]}`))
	rc := canonFromResponses(resp)
	if rc.system != "inst\n\ndev note" || !rc.customTools()["apply_patch"] {
		t.Errorf("responses → canon: %q %v", rc.system, rc.customTools())
	}
	rb := rc.anthropicBody("claude-x")
	var rroles []string
	for _, m := range jarr(rb["messages"]) {
		rroles = append(rroles, jstr(jobj(m)["role"]))
	}
	if strings.Join(rroles, ",") != "user,assistant,user,assistant,user" {
		t.Errorf("responses → anthropic turns: %v", rroles)
	}

	dec := newAnthropicDecoder()
	enc := newResponsesEncoder("m", map[string]bool{"apply_patch": true})
	var out strings.Builder
	for _, e := range []string{
		`{"type":"message_start","message":{"id":"m1","model":"m","usage":{"input_tokens":3}}}`,
		`{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
		`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Patching"}}`,
		`{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"apply_patch","input":{}}}`,
		`{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"input\":\"*** Begin"}}`,
		`{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" Patch\"}"}}`,
		`{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":4}}`,
		`{"type":"message_stop"}`,
	} {
		for _, ev := range dec.decode(e) {
			out.WriteString(enc.encode(ev))
		}
	}
	ps := payloads(out.String())
	if ps[0]["type"] != "response.created" || ps[len(ps)-1]["type"] != "response.completed" {
		t.Fatalf("responses lifecycle: %v", ps)
	}
	items := jarr(jobj(ps[len(ps)-1]["response"])["output"])
	if len(items) != 2 || jobj(items[1])["type"] != "custom_tool_call" || jobj(items[1])["input"] != "*** Begin Patch" {
		t.Errorf("custom_tool_call: %v", items)
	}
	for i, p := range ps {
		if n, _ := jint(p["sequence_number"]); n != i {
			t.Errorf("sequence %d = %d", i, n)
		}
	}
}

func TestPricing(t *testing.T) {
	check := func(model string, p Provider, field func(Price) float64, want float64) {
		got := PriceFor(model, p, nil)
		if got == nil || field(*got) != want {
			t.Errorf("%s: %v want %v", model, got, want)
		}
	}
	in := func(p Price) float64 { return p.Input }
	check("claude-opus-4-1-20250805", Anthropic, in, 15)
	check("claude-opus-4-5-20251101", Anthropic, in, 5)
	check("gpt-5.1-codex", OpenAI, in, 1.25)
	check("gpt-5.4-mini-2026-03-17", OpenAI, func(p Price) float64 { return p.Output }, 4.5)
	check("llama-3.3", Compatible, in, 0)
	if PriceFor("grok-9", XAI, nil) != nil {
		t.Error("unknown model should have no price")
	}
	if p := PriceFor("grok-9", XAI, map[string]Price{"grok": {3, 15, 3, 3}}); p == nil || p.Output != 15 {
		t.Error("override")
	}
	if c := (Price{2, 10, 0.2, 2.5}).Cost(Usage{1000, 500, 10000, 0}); math.Abs(c-0.009) > 1e-9 {
		t.Errorf("cost %v", c)
	}
	if limitCooldown(429, nil, "30") != 30*time.Second || limitCooldown(400, []byte(`{"error":{"message":"Your credit balance is too low"}}`), "") != 15*time.Minute ||
		limitCooldown(400, []byte(`{"error":{"message":"bad field"}}`), "") != 0 {
		t.Error("limitCooldown")
	}
}

// --- End to end ---------------------------------------------------------------------

func TestEndToEnd(t *testing.T) {
	e, url, ml := setup(t)
	tok := "prism-test-token"

	if r := call(t, url, "POST", "/v1/chat/completions", obj{"model": "gpt-test", "messages": []any{obj{"role": "user", "content": "hi"}}}, "", false, ""); r.status != 401 {
		t.Errorf("no token: %d", r.status)
	}
	r := call(t, url, "GET", "/v1/models", nil, tok, false, "")
	ids := map[string]bool{}
	for _, m := range jarr(r.json()["data"]) {
		ids[jstr(jobj(m)["id"])] = true
	}
	if !ids["work/claude-test-sonnet"] || !ids["personal/gpt-test"] || !ids["claude-test-sonnet"] || ids["text-embedding-3-small"] {
		t.Errorf("models: %v", ids)
	}

	r = call(t, url, "POST", "/v1/chat/completions", obj{"model": "work/claude-test-sonnet", "messages": []any{obj{"role": "user", "content": "hello"}}}, tok, false, "")
	content := jstr(jobj(jobj(jarr(r.json()["choices"])[0])["message"])["content"])
	if content != "key=ak-work said=hello" || r.headers.Get("X-Prism-Identity") != "Work" || jstr(ml.get("/anthropic/v1/messages")["model"]) != "claude-test-sonnet" {
		t.Errorf("chat → anthropic: %d %s", r.status, r.body)
	}

	r = call(t, url, "POST", "/v1/chat/completions", obj{"model": "claude-test-sonnet", "stream": true, "messages": []any{obj{"role": "user", "content": "@work go"}}}, tok, false, "")
	var text strings.Builder
	for _, p := range payloads(r.body) {
		text.WriteString(jstr(jobj(jobj(firstOf(jarr(p["choices"])))["delta"])["content"]))
	}
	if text.String() != "key=ak-work said=go" || !strings.HasSuffix(r.body, "data: [DONE]\n\n") {
		t.Errorf("chat stream ← anthropic: %q %q", text.String(), r.body)
	}

	r = call(t, url, "POST", "/v1/messages", obj{"model": "work/gpt-test", "max_tokens": 100, "stream": true,
		"messages": []any{obj{"role": "user", "content": "weather?"}}, "tools": []any{obj{"name": "get_weather", "input_schema": obj{"type": "object"}}}}, tok, true, "")
	var atext, args strings.Builder
	stop := ""
	for _, p := range payloads(r.body) {
		d := jobj(p["delta"])
		atext.WriteString(jstr(d["text"]))
		args.WriteString(jstr(d["partial_json"]))
		if p["type"] == "message_delta" {
			stop = jstr(d["stop_reason"])
		}
	}
	if atext.String() != "key=ok-work said=weather?" || args.String() != `{"city":"Sydney"}` || stop != "tool_use" {
		t.Errorf("anthropic stream ← openai: %q %q %q", atext.String(), args.String(), stop)
	}

	r = call(t, url, "POST", "/v1/messages?beta=true", obj{"model": "claude-test-sonnet", "max_tokens": 10, "messages": []any{obj{"role": "user", "content": "standup notes"}}}, tok, true, "")
	if jstr(jobj(jarr(r.json()["content"])[0])["text"]) != "key=ak-work said=standup notes" {
		t.Errorf("passthrough + keyword rule: %s", r.body)
	}

	r = call(t, url, "POST", "/v1/messages", obj{"model": "claude-test-sonnet", "max_tokens": 10, "thinking": obj{"type": "enabled", "budget_tokens": 1024},
		"messages": []any{obj{"role": "user", "content": "hi"}, obj{"role": "assistant", "content": []any{obj{"type": "thinking", "thinking": "x", "signature": "o"}, obj{"type": "text", "text": "yo"}}},
			obj{"role": "user", "content": "again"}}}, tok, true, "")
	if r.status != 200 {
		t.Errorf("thinking retry: %d %s", r.status, r.body)
	}

	r = call(t, url, "POST", "/v1/responses", obj{"model": "personal/gpt-test", "stream": true, "store": false,
		"input": []any{obj{"type": "message", "role": "user", "content": []any{obj{"type": "input_text", "text": "hi"}}}, obj{"type": "reasoning", "encrypted_content": "w"}}}, tok, false, "codex_cli_rs/0.50")
	if r.status != 200 || !strings.Contains(r.body, "key=ok-personal") {
		t.Errorf("responses passthrough retry: %d %s", r.status, r.body)
	}

	r = call(t, url, "POST", "/v1/responses", obj{"model": "work/claude-test-sonnet", "stream": true, "store": false,
		"input": []any{obj{"type": "message", "role": "user", "content": []any{obj{"type": "input_text", "text": "patch it"}}}},
		"tools": []any{obj{"type": "function", "name": "get_weather", "parameters": obj{"type": "object"}}}}, tok, false, "")
	var done obj
	for _, p := range payloads(r.body) {
		if p["type"] == "response.completed" {
			done = jobj(p["response"])
		}
	}
	items := jarr(done["output"])
	if len(items) != 2 || jobj(items[1])["arguments"] != `{"city":"Sydney"}` {
		t.Errorf("responses ← anthropic: %s", r.body)
	}

	r = call(t, url, "POST", "/v1/responses", obj{"model": "work/claude-test-sonnet", "input": "plain string"}, tok, false, "")
	if jstr(jobj(jarr(jobj(jarr(r.json()["output"])[0])["content"])[0])["text"]) != "key=ak-work said=plain string" {
		t.Errorf("responses non-stream: %s", r.body)
	}

	// Limits and usage.
	cfg := e.Config()
	cfg.Identities[0].FallbackIdentityID = "personal-id"
	cfg.PriceOverrides = map[string]Price{"claude-test": {1000, 2000, 1000, 1000}}
	e.SetConfig(cfg)

	r = call(t, url, "POST", "/v1/messages", obj{"model": "work/claude-test-sonnet", "max_tokens": 10, "stream": true, "messages": []any{obj{"role": "user", "content": "count me"}}}, tok, true, "")
	last := e.Log()[0]
	if last.InputTokens != 11 || last.OutputTokens != 7 || last.Cost == nil || math.Abs(*last.Cost-(11*1000.0+7*2000.0)/1e6) > 1e-9 {
		t.Errorf("stream usage: %+v", last)
	}
	if e.Usage.Month("work-id", time.Now()).Requests == 0 {
		t.Error("usage stored")
	}

	r = call(t, url, "POST", "/v1/chat/completions", obj{"model": "claude-test-sonnet", "messages": []any{obj{"role": "user", "content": "pinned"}}}, "prism-work-token", false, "")
	if r.headers.Get("X-Prism-Identity") != "Work" {
		t.Errorf("identity token: %s", r.headers.Get("X-Prism-Identity"))
	}

	r = call(t, url, "POST", "/v1/chat/completions", obj{"model": "work/claude-test-sonnet", "messages": []any{obj{"role": "user", "content": "ratelimit please"}}}, tok, false, "")
	if c := jstr(jobj(jobj(jarr(r.json()["choices"])[0])["message"])["content"]); c != "key=ak-personal said=ratelimit please" {
		t.Errorf("429 failover: %d %s", r.status, r.body)
	}
	if !strings.Contains(e.Log()[0].Note, "Work rate-limited (429) → Personal") {
		t.Errorf("failover note: %q", e.Log()[0].Note)
	}
	if _, ok := e.Cooldown("work-id", Anthropic); !ok {
		t.Error("cooldown")
	}
	r = call(t, url, "POST", "/v1/messages", obj{"model": "work/claude-test-sonnet", "max_tokens": 10, "messages": []any{obj{"role": "user", "content": "while cooling"}}}, tok, true, "")
	if jstr(jobj(jarr(r.json()["content"])[0])["text"]) != "key=ak-personal said=while cooling" {
		t.Errorf("cooling → fallback: %s", r.body)
	}
	e.CoolDown("work-id", Anthropic, -time.Second)

	cfg.Identities[0].FallbackIdentityID = ""
	e.SetConfig(cfg)
	if r = call(t, url, "POST", "/v1/messages", obj{"model": "work/claude-test-sonnet", "max_tokens": 10, "messages": []any{obj{"role": "user", "content": "ratelimit"}}}, tok, true, ""); r.status != 429 {
		t.Errorf("no fallback → 429: %d", r.status)
	}
	e.CoolDown("work-id", Anthropic, -time.Second)

	cfg.Identities[0].MonthlyBudget = 0.0000001
	cfg.Identities[0].BudgetAction = BudgetBlock
	e.SetConfig(cfg)
	if r = call(t, url, "POST", "/v1/messages", obj{"model": "work/claude-test-sonnet", "max_tokens": 10, "messages": []any{obj{"role": "user", "content": "x"}}}, tok, true, ""); r.status != 429 || !strings.Contains(r.body, "monthly budget") {
		t.Errorf("budget block: %d %s", r.status, r.body)
	}

	// Admin API.
	if r = call(t, url, "GET", "/prism/status", nil, "prism-work-token", false, ""); r.status != 401 {
		t.Errorf("admin needs the main token: %d", r.status)
	}
	r = call(t, url, "GET", "/prism/status", nil, tok, false, "")
	st := r.json()
	if len(jarr(st["identities"])) != 2 || len(jarr(st["log"])) == 0 {
		t.Errorf("status: %s", r.body)
	}
	if r = call(t, url, "POST", "/prism/active", obj{"identityID": "work-id"}, tok, false, ""); r.status != 200 || e.Config().ActiveIdentityID != "work-id" {
		t.Errorf("set active: %d %s", r.status, r.body)
	}
	if r = call(t, url, "POST", "/prism/check", obj{"credentialID": "work-openai"}, tok, false, ""); !strings.Contains(r.body, "gpt-test") {
		t.Errorf("check: %s", r.body)
	}
}

func TestConfigRoundTrip(t *testing.T) {
	// A config written by the macOS app.
	mac := `{"enabled":true,"port":4848,"allowLAN":false,"requireToken":true,"token":"prism-abc","tagsEnabled":true,"modelList":"both",
	 "identities":[{"id":"W","name":"Work","colorHex":"#3B82F6","credentials":[{"id":"c1","provider":"anthropic","baseURL":""}],"defaultModel":"claude-sonnet-5","token":"prism-w","budgetAction":"fallback","monthlyBudget":50}],
	 "rules":[{"id":"r","enabled":true,"kind":"client","pattern":"codex","days":[2,3,4,5,6],"startMinute":540,"endMinute":1020,"identityID":"W"}],
	 "priceOverrides":{"grok":{"input":3,"output":15,"cacheRead":3,"cacheWrite":3}}}`
	dir := t.TempDir()
	path := dir + "/endpoint.json"
	if err := writeFile(path, mac); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil || c.Identities[0].MonthlyBudget != 50 || c.Rules[0].Kind != RuleClient || c.PriceOverrides["grok"].Output != 15 {
		t.Fatalf("load mac config: %v %+v", err, c)
	}
	if err := Save(path, c); err != nil {
		t.Fatal(err)
	}
	c2, _ := Load(path)
	if c2.Identities[0].Token != "prism-w" || c2.Token != "prism-abc" {
		t.Errorf("round trip: %+v", c2)
	}
}

func writeFile(path, s string) error { return os.WriteFile(path, []byte(s), 0o600) }
