package endpoint

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"math"
	"strings"
)

// Clients speak Anthropic Messages, OpenAI Chat Completions or OpenAI
// Responses; providers speak Messages (Anthropic) or Chat (OpenAI, xAI,
// local servers). Same-API requests pass through; otherwise requests are
// parsed into canonRequest and rebuilt, and replies converted back.

type obj = map[string]any

type API string

const (
	APIAnthropic API = "anthropic"
	APIChat      API = "chat"
	APIResponses API = "responses"
)

func (a API) Label() string {
	switch a {
	case APIAnthropic:
		return "Messages"
	case APIChat:
		return "Chat"
	}
	return "Responses"
}

// --- JSON helpers -----------------------------------------------------

func parseJSON(data []byte) obj {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var o obj
	if err := d.Decode(&o); err != nil {
		return nil
	}
	return o
}

func parseAny(s string) any {
	d := json.NewDecoder(strings.NewReader(s))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil
	}
	return v
}

func toJSON(v any) []byte {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	_ = e.Encode(v)
	return bytes.TrimRight(b.Bytes(), "\n")
}

func jstr(v any) string {
	s, _ := v.(string)
	return s
}

func jobj(v any) obj {
	o, _ := v.(obj)
	return o
}

func jarr(v any) []any {
	a, _ := v.([]any)
	return a
}

func jbool(v any) (bool, bool) {
	b, ok := v.(bool)
	return b, ok
}

func jfloat(v any) (float64, bool) {
	switch n := v.(type) {
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	case float64:
		return n, true
	case int:
		return float64(n), true
	}
	return 0, false
}

func jint(v any) (int, bool) {
	f, ok := jfloat(v)
	return int(f), ok
}

func newID(prefix string) string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return prefix + hex.EncodeToString(b)
}

// toolID makes an id Anthropic accepts (^[a-zA-Z0-9_-]+$).
func toolID(raw string) string {
	var b strings.Builder
	for _, r := range raw {
		if r < 128 && (r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-') {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	if b.Len() == 0 {
		return newID("toolu_")
	}
	return b.String()
}

// --- Canonical request --------------------------------------------------

type partKind int

const (
	partText partKind = iota
	partImage
	partToolCall
	partToolResult
)

type canonPart struct {
	kind      partKind
	text      string // text, tool result content, tool call arguments
	mediaType string
	base64    string
	url       string
	id        string // tool call / result id
	name      string
	isError   bool
}

type canonMessage struct {
	assistant bool
	parts     []canonPart
}

type canonTool struct {
	name, description string
	schema            obj
	custom            bool
}

type canonRequest struct {
	model           string
	system          string
	messages        []canonMessage
	tools           []canonTool
	toolChoice      string // "", auto, none, required, or a tool name after "name:"
	maxTokens       *int
	temperature     *float64
	topP            *float64
	stop            []string
	stream          bool
	reasoningEffort string
	parallel        *bool
}

func (r canonRequest) customTools() map[string]bool {
	m := map[string]bool{}
	for _, t := range r.tools {
		if t.custom {
			m[t.name] = true
		}
	}
	return m
}

func dataURL(media, b64 string) string { return "data:" + media + ";base64," + b64 }

func imageFromURL(u string) canonPart {
	if strings.HasPrefix(u, "data:") {
		if comma := strings.Index(u, ","); comma > 0 {
			meta := u[5:comma]
			if strings.HasSuffix(meta, ";base64") {
				media := strings.TrimSuffix(meta, ";base64")
				if media == "" {
					media = "image/png"
				}
				return canonPart{kind: partImage, mediaType: media, base64: u[comma+1:]}
			}
		}
	}
	return canonPart{kind: partImage, mediaType: "image/png", url: u}
}

func flattenText(content any) string {
	if s, ok := content.(string); ok {
		return s
	}
	var out []string
	for _, b := range jarr(content) {
		o := jobj(b)
		if t, ok := o["text"].(string); ok {
			out = append(out, t)
		} else if strings.Contains(jstr(o["type"]), "image") {
			out = append(out, "[image]")
		}
	}
	return strings.Join(out, "\n")
}

func stopList(v any) []string {
	if s, ok := v.(string); ok {
		return []string{s}
	}
	var out []string
	for _, x := range jarr(v) {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func optInt(v any) *int {
	if n, ok := jint(v); ok {
		return &n
	}
	return nil
}

func optFloat(v any) *float64 {
	if n, ok := jfloat(v); ok {
		return &n
	}
	return nil
}

func (r *canonRequest) appendTurn(assistant bool, parts []canonPart) {
	if n := len(r.messages); n > 0 && r.messages[n-1].assistant == assistant {
		r.messages[n-1].parts = append(r.messages[n-1].parts, parts...)
		return
	}
	r.messages = append(r.messages, canonMessage{assistant: assistant, parts: parts})
}

func openAIToolChoice(v any) string {
	switch s := v.(type) {
	case string:
		if s == "none" || s == "required" || s == "auto" {
			return s
		}
	case obj:
		if name := jstr(jobj(s["function"])["name"]); name != "" {
			return "name:" + name
		}
		if name := jstr(s["name"]); name != "" {
			return "name:" + name
		}
	}
	return ""
}

func canonFromAnthropic(j obj) canonRequest {
	r := canonRequest{model: jstr(j["model"])}
	if s, ok := j["system"].(string); ok {
		r.system = s
	} else {
		r.system = flattenText(j["system"])
	}
	for _, mv := range jarr(j["messages"]) {
		m := jobj(mv)
		assistant := jstr(m["role"]) == "assistant"
		var parts []canonPart
		if s, ok := m["content"].(string); ok {
			parts = append(parts, canonPart{kind: partText, text: s})
		} else {
			for _, bv := range jarr(m["content"]) {
				b := jobj(bv)
				switch jstr(b["type"]) {
				case "text":
					parts = append(parts, canonPart{kind: partText, text: jstr(b["text"])})
				case "image":
					src := jobj(b["source"])
					if jstr(src["type"]) == "url" {
						parts = append(parts, canonPart{kind: partImage, mediaType: "image/png", url: jstr(src["url"])})
					} else {
						media := jstr(src["media_type"])
						if media == "" {
							media = "image/png"
						}
						parts = append(parts, canonPart{kind: partImage, mediaType: media, base64: jstr(src["data"])})
					}
				case "tool_use", "server_tool_use":
					input := b["input"]
					if input == nil {
						input = obj{}
					}
					id := jstr(b["id"])
					if id == "" {
						id = newID("toolu_")
					}
					parts = append(parts, canonPart{kind: partToolCall, id: id, name: jstr(b["name"]), text: string(toJSON(input))})
				case "tool_result":
					isErr, _ := jbool(b["is_error"])
					parts = append(parts, canonPart{kind: partToolResult, id: jstr(b["tool_use_id"]), text: flattenText(b["content"]), isError: isErr})
				case "document":
					parts = append(parts, canonPart{kind: partText, text: "[document omitted]"})
				}
			}
		}
		r.messages = append(r.messages, canonMessage{assistant: assistant, parts: parts})
	}
	for _, tv := range jarr(j["tools"]) {
		t := jobj(tv)
		name := jstr(t["name"])
		if name == "" || (t["input_schema"] == nil && t["type"] != nil) {
			continue // server tools exist only on Anthropic
		}
		schema := jobj(t["input_schema"])
		if schema == nil {
			schema = obj{"type": "object"}
		}
		r.tools = append(r.tools, canonTool{name: name, description: jstr(t["description"]), schema: schema})
	}
	if tc := jobj(j["tool_choice"]); tc != nil {
		switch jstr(tc["type"]) {
		case "any":
			r.toolChoice = "required"
		case "none":
			r.toolChoice = "none"
		case "tool":
			r.toolChoice = "name:" + jstr(tc["name"])
		default:
			r.toolChoice = "auto"
		}
		if off, ok := jbool(tc["disable_parallel_tool_use"]); ok {
			p := !off
			r.parallel = &p
		}
	}
	r.maxTokens = optInt(j["max_tokens"])
	r.temperature = optFloat(j["temperature"])
	r.topP = optFloat(j["top_p"])
	r.stop = stopList(j["stop_sequences"])
	r.stream, _ = jbool(j["stream"])
	return r
}

func canonFromChat(j obj) canonRequest {
	r := canonRequest{model: jstr(j["model"])}
	var system []string
	for _, mv := range jarr(j["messages"]) {
		m := jobj(mv)
		switch role := jstr(m["role"]); role {
		case "system", "developer":
			if t := flattenText(m["content"]); t != "" {
				system = append(system, t)
			}
		case "assistant":
			var parts []canonPart
			if t := flattenText(m["content"]); t != "" {
				parts = append(parts, canonPart{kind: partText, text: t})
			}
			for _, cv := range jarr(m["tool_calls"]) {
				c := jobj(cv)
				fn := jobj(c["function"])
				id := jstr(c["id"])
				if id == "" {
					id = newID("call_")
				}
				args := jstr(fn["arguments"])
				if args == "" {
					args = "{}"
				}
				parts = append(parts, canonPart{kind: partToolCall, id: id, name: jstr(fn["name"]), text: args})
			}
			r.messages = append(r.messages, canonMessage{assistant: true, parts: parts})
		case "tool", "function":
			part := canonPart{kind: partToolResult, id: jstr(m["tool_call_id"]), text: flattenText(m["content"])}
			n := len(r.messages)
			if n > 0 && !r.messages[n-1].assistant && allToolResults(r.messages[n-1].parts) {
				r.messages[n-1].parts = append(r.messages[n-1].parts, part)
			} else {
				r.messages = append(r.messages, canonMessage{parts: []canonPart{part}})
			}
		default:
			var parts []canonPart
			if s, ok := m["content"].(string); ok {
				parts = append(parts, canonPart{kind: partText, text: s})
			} else {
				for _, pv := range jarr(m["content"]) {
					p := jobj(pv)
					switch jstr(p["type"]) {
					case "text":
						parts = append(parts, canonPart{kind: partText, text: jstr(p["text"])})
					case "image_url":
						u := jstr(jobj(p["image_url"])["url"])
						if u == "" {
							u = jstr(p["image_url"])
						}
						parts = append(parts, imageFromURL(u))
					}
				}
			}
			r.messages = append(r.messages, canonMessage{parts: parts})
		}
	}
	r.system = strings.Join(system, "\n\n")
	for _, tv := range jarr(j["tools"]) {
		fn := jobj(jobj(tv)["function"])
		if jstr(fn["name"]) == "" {
			continue
		}
		schema := jobj(fn["parameters"])
		if schema == nil {
			schema = obj{"type": "object", "properties": obj{}}
		}
		r.tools = append(r.tools, canonTool{name: jstr(fn["name"]), description: jstr(fn["description"]), schema: schema})
	}
	r.toolChoice = openAIToolChoice(j["tool_choice"])
	r.maxTokens = optInt(j["max_completion_tokens"])
	if r.maxTokens == nil {
		r.maxTokens = optInt(j["max_tokens"])
	}
	r.temperature = optFloat(j["temperature"])
	r.topP = optFloat(j["top_p"])
	r.stop = stopList(j["stop"])
	r.stream, _ = jbool(j["stream"])
	r.reasoningEffort = jstr(j["reasoning_effort"])
	if p, ok := jbool(j["parallel_tool_calls"]); ok {
		r.parallel = &p
	}
	return r
}

func allToolResults(parts []canonPart) bool {
	for _, p := range parts {
		if p.kind != partToolResult {
			return false
		}
	}
	return true
}

func canonFromResponses(j obj) canonRequest {
	r := canonRequest{model: jstr(j["model"])}
	var system []string
	if s := jstr(j["instructions"]); s != "" {
		system = append(system, s)
	}
	if s, ok := j["input"].(string); ok {
		r.messages = append(r.messages, canonMessage{parts: []canonPart{{kind: partText, text: s}}})
	}
	for _, iv := range jarr(j["input"]) {
		item := jobj(iv)
		typ := jstr(item["type"])
		if typ == "" && item["role"] != nil {
			typ = "message"
		}
		switch typ {
		case "message":
			role := jstr(item["role"])
			if role == "system" || role == "developer" {
				if t := flattenText(item["content"]); t != "" {
					system = append(system, t)
				}
				continue
			}
			var parts []canonPart
			if s, ok := item["content"].(string); ok {
				parts = append(parts, canonPart{kind: partText, text: s})
			} else {
				for _, pv := range jarr(item["content"]) {
					p := jobj(pv)
					switch jstr(p["type"]) {
					case "input_text", "output_text", "text":
						parts = append(parts, canonPart{kind: partText, text: jstr(p["text"])})
					case "refusal":
						parts = append(parts, canonPart{kind: partText, text: jstr(p["refusal"])})
					case "input_image":
						u := jstr(p["image_url"])
						if u == "" {
							u = jstr(jobj(p["image_url"])["url"])
						}
						if u != "" {
							parts = append(parts, imageFromURL(u))
						}
					}
				}
			}
			r.appendTurn(role == "assistant", parts)
		case "function_call":
			args := jstr(item["arguments"])
			if args == "" {
				args = "{}"
			}
			r.appendTurn(true, []canonPart{{kind: partToolCall, id: jstr(item["call_id"]), name: jstr(item["name"]), text: args}})
		case "custom_tool_call":
			args := string(toJSON(obj{"input": jstr(item["input"])}))
			r.appendTurn(true, []canonPart{{kind: partToolCall, id: jstr(item["call_id"]), name: jstr(item["name"]), text: args}})
		case "function_call_output", "custom_tool_call_output":
			r.appendTurn(false, []canonPart{{kind: partToolResult, id: jstr(item["call_id"]), text: flattenText(item["output"])}})
		}
	}
	r.system = strings.Join(system, "\n\n")
	for _, tv := range jarr(j["tools"]) {
		t := jobj(tv)
		name := jstr(t["name"])
		if name == "" {
			continue
		}
		switch jstr(t["type"]) {
		case "function":
			schema := jobj(t["parameters"])
			if schema == nil {
				schema = obj{"type": "object", "properties": obj{}}
			}
			r.tools = append(r.tools, canonTool{name: name, description: jstr(t["description"]), schema: schema})
		case "custom":
			r.tools = append(r.tools, canonTool{name: name, description: jstr(t["description"]), custom: true,
				schema: obj{"type": "object", "properties": obj{"input": obj{"type": "string", "description": "The raw text input for this tool."}}, "required": []any{"input"}}})
		}
	}
	r.toolChoice = openAIToolChoice(j["tool_choice"])
	r.maxTokens = optInt(j["max_output_tokens"])
	r.temperature = optFloat(j["temperature"])
	r.topP = optFloat(j["top_p"])
	r.stream, _ = jbool(j["stream"])
	r.reasoningEffort = jstr(jobj(j["reasoning"])["effort"])
	if p, ok := jbool(j["parallel_tool_calls"]); ok {
		r.parallel = &p
	}
	return r
}

// --- Build requests -----------------------------------------------------

func (r canonRequest) anthropicBody(model string) obj {
	type turn struct {
		role   string
		blocks []any
	}
	var turns []turn
	for _, m := range r.messages {
		role := "user"
		if m.assistant {
			role = "assistant"
		}
		var results, blocks []any
		for _, p := range m.parts {
			switch p.kind {
			case partText:
				if p.text != "" {
					blocks = append(blocks, obj{"type": "text", "text": p.text})
				}
			case partImage:
				if p.base64 != "" {
					blocks = append(blocks, obj{"type": "image", "source": obj{"type": "base64", "media_type": p.mediaType, "data": p.base64}})
				} else if p.url != "" {
					blocks = append(blocks, obj{"type": "image", "source": obj{"type": "url", "url": p.url}})
				}
			case partToolCall:
				input := jobj(parseAny(p.text))
				if input == nil {
					input = obj{}
				}
				blocks = append(blocks, obj{"type": "tool_use", "id": toolID(p.id), "name": p.name, "input": input})
			case partToolResult:
				content := p.text
				if content == "" {
					content = "(empty)"
				}
				res := obj{"type": "tool_result", "tool_use_id": toolID(p.id), "content": content}
				if p.isError {
					res["is_error"] = true
				}
				results = append(results, res)
			}
		}
		all := append(results, blocks...)
		if len(all) == 0 {
			continue
		}
		if n := len(turns); n > 0 && turns[n-1].role == role {
			turns[n-1].blocks = append(turns[n-1].blocks, all...)
		} else {
			turns = append(turns, turn{role, all})
		}
	}
	if len(turns) > 0 && turns[0].role == "assistant" {
		turns = append([]turn{{"user", []any{obj{"type": "text", "text": "(continuing the conversation)"}}}}, turns...)
	}
	msgs := make([]any, 0, len(turns))
	for _, t := range turns {
		msgs = append(msgs, obj{"role": t.role, "content": t.blocks})
	}
	maxTokens := 8192
	if r.maxTokens != nil {
		maxTokens = *r.maxTokens
	}
	body := obj{"model": model, "max_tokens": maxTokens, "messages": msgs}
	if r.system != "" {
		body["system"] = r.system
	}
	if len(r.tools) > 0 {
		var tools []any
		for _, t := range r.tools {
			o := obj{"name": t.name, "input_schema": t.schema}
			if t.description != "" {
				o["description"] = t.description
			}
			tools = append(tools, o)
		}
		body["tools"] = tools
		if r.toolChoice != "" {
			var tc obj
			switch {
			case r.toolChoice == "none":
				tc = obj{"type": "none"}
			case r.toolChoice == "required":
				tc = obj{"type": "any"}
			case strings.HasPrefix(r.toolChoice, "name:"):
				tc = obj{"type": "tool", "name": strings.TrimPrefix(r.toolChoice, "name:")}
			default:
				tc = obj{"type": "auto"}
			}
			if r.parallel != nil && !*r.parallel && r.toolChoice != "none" {
				tc["disable_parallel_tool_use"] = true
			}
			body["tool_choice"] = tc
		}
	}
	if r.temperature != nil {
		body["temperature"] = math.Min(math.Max(*r.temperature, 0), 1)
	} else if r.topP != nil {
		body["top_p"] = *r.topP
	}
	if len(r.stop) > 0 {
		body["stop_sequences"] = r.stop
	}
	if r.stream {
		body["stream"] = true
	}
	return body
}

func (r canonRequest) chatBody(model string, provider Provider) obj {
	var msgs []any
	if r.system != "" {
		msgs = append(msgs, obj{"role": "system", "content": r.system})
	}
	for _, m := range r.messages {
		if m.assistant {
			var text []string
			var calls []any
			for _, p := range m.parts {
				switch p.kind {
				case partText:
					text = append(text, p.text)
				case partToolCall:
					calls = append(calls, obj{"id": p.id, "type": "function", "function": obj{"name": p.name, "arguments": p.text}})
				}
			}
			o := obj{"role": "assistant"}
			joined := strings.Join(text, "\n\n")
			if joined == "" && len(calls) > 0 {
				o["content"] = nil
			} else {
				o["content"] = joined
			}
			if len(calls) > 0 {
				o["tool_calls"] = calls
			}
			msgs = append(msgs, o)
			continue
		}
		var content []obj
		hasImage := false
		for _, p := range m.parts {
			switch p.kind {
			case partToolResult:
				c := p.text
				if p.isError {
					c = "Error: " + c
				}
				msgs = append(msgs, obj{"role": "tool", "tool_call_id": p.id, "content": c})
			case partText:
				content = append(content, obj{"type": "text", "text": p.text})
			case partImage:
				hasImage = true
				u := p.url
				if p.base64 != "" {
					u = dataURL(p.mediaType, p.base64)
				}
				content = append(content, obj{"type": "image_url", "image_url": obj{"url": u}})
			}
		}
		if len(content) == 0 {
			continue
		}
		if hasImage {
			arr := make([]any, len(content))
			for i, c := range content {
				arr[i] = c
			}
			msgs = append(msgs, obj{"role": "user", "content": arr})
		} else {
			var t []string
			for _, c := range content {
				t = append(t, jstr(c["text"]))
			}
			msgs = append(msgs, obj{"role": "user", "content": strings.Join(t, "\n\n")})
		}
	}
	body := obj{"model": model, "messages": msgs}
	if len(r.tools) > 0 {
		var tools []any
		for _, t := range r.tools {
			fn := obj{"name": t.name, "parameters": t.schema}
			if t.description != "" {
				fn["description"] = t.description
			}
			tools = append(tools, obj{"type": "function", "function": fn})
		}
		body["tools"] = tools
		switch {
		case r.toolChoice == "auto" || r.toolChoice == "none" || r.toolChoice == "required":
			body["tool_choice"] = r.toolChoice
		case strings.HasPrefix(r.toolChoice, "name:"):
			body["tool_choice"] = obj{"type": "function", "function": obj{"name": strings.TrimPrefix(r.toolChoice, "name:")}}
		}
		if r.parallel != nil {
			body["parallel_tool_calls"] = *r.parallel
		}
	}
	if r.maxTokens != nil {
		if provider == OpenAI {
			body["max_completion_tokens"] = *r.maxTokens
		} else {
			body["max_tokens"] = *r.maxTokens
		}
	}
	if r.temperature != nil {
		body["temperature"] = *r.temperature
	}
	if r.topP != nil {
		body["top_p"] = *r.topP
	}
	if len(r.stop) > 0 {
		body["stop"] = r.stop
	}
	if provider == OpenAI && r.reasoningEffort != "" {
		body["reasoning_effort"] = r.reasoningEffort
	}
	if r.stream {
		body["stream"] = true
		if provider == OpenAI || provider == XAI {
			body["stream_options"] = obj{"include_usage": true}
		}
	}
	return body
}

// --- Replies ------------------------------------------------------------

type stopReason int

const (
	stopEnd stopReason = iota
	stopMax
	stopTool
	stopSeq
	stopRefusal
)

func (s stopReason) anthropic() string {
	return [...]string{"end_turn", "max_tokens", "tool_use", "stop_sequence", "refusal"}[s]
}

func (s stopReason) chat() string {
	return [...]string{"stop", "length", "tool_calls", "stop", "content_filter"}[s]
}

func stopFromAnthropic(s string) stopReason {
	switch s {
	case "max_tokens", "model_context_window_exceeded":
		return stopMax
	case "tool_use":
		return stopTool
	case "stop_sequence":
		return stopSeq
	case "refusal":
		return stopRefusal
	}
	return stopEnd
}

func stopFromChat(s string) stopReason {
	switch s {
	case "length":
		return stopMax
	case "tool_calls", "function_call":
		return stopTool
	case "content_filter":
		return stopRefusal
	}
	return stopEnd
}

// Usage counts tokens; Input is uncached input (Anthropic's meaning).
type Usage struct {
	Input, Output, CacheRead, CacheWrite int
}

func (u Usage) TotalInput() int { return u.Input + u.CacheRead + u.CacheWrite }

func usageFromAnthropic(u obj) Usage {
	in, _ := jint(u["input_tokens"])
	out, _ := jint(u["output_tokens"])
	cr, _ := jint(u["cache_read_input_tokens"])
	cw, _ := jint(u["cache_creation_input_tokens"])
	return Usage{in, out, cr, cw}
}

func usageFromChat(u obj) Usage {
	p, _ := jint(u["prompt_tokens"])
	cached, _ := jint(jobj(u["prompt_tokens_details"])["cached_tokens"])
	out, _ := jint(u["completion_tokens"])
	in := p - cached
	if in < 0 {
		in = 0
	}
	return Usage{Input: in, Output: out, CacheRead: cached}
}

func usageFromResponses(u obj) Usage {
	total, _ := jint(u["input_tokens"])
	cached, _ := jint(jobj(u["input_tokens_details"])["cached_tokens"])
	out, _ := jint(u["output_tokens"])
	in := total - cached
	if in < 0 {
		in = 0
	}
	return Usage{Input: in, Output: out, CacheRead: cached}
}

func usageFromReply(j obj, api API) Usage {
	switch api {
	case APIAnthropic:
		return usageFromAnthropic(jobj(j["usage"]))
	case APIChat:
		return usageFromChat(jobj(j["usage"]))
	}
	return usageFromResponses(jobj(j["usage"]))
}

func (u Usage) anthropicJSON() obj {
	o := obj{"input_tokens": u.Input, "output_tokens": u.Output}
	if u.CacheRead > 0 {
		o["cache_read_input_tokens"] = u.CacheRead
	}
	if u.CacheWrite > 0 {
		o["cache_creation_input_tokens"] = u.CacheWrite
	}
	return o
}

func (u Usage) chatJSON() obj {
	return obj{"prompt_tokens": u.TotalInput(), "completion_tokens": u.Output, "total_tokens": u.TotalInput() + u.Output,
		"prompt_tokens_details": obj{"cached_tokens": u.CacheRead}}
}

func (u Usage) responsesJSON() obj {
	return obj{"input_tokens": u.TotalInput(), "output_tokens": u.Output, "total_tokens": u.TotalInput() + u.Output,
		"input_tokens_details": obj{"cached_tokens": u.CacheRead}, "output_tokens_details": obj{"reasoning_tokens": 0}}
}

type canonResponse struct {
	parts     []canonPart // text and tool calls
	reasoning string
	stop      stopReason
	usage     Usage
}

func responseFromAnthropic(j obj) canonResponse {
	var r canonResponse
	for _, bv := range jarr(j["content"]) {
		b := jobj(bv)
		switch jstr(b["type"]) {
		case "text":
			r.parts = append(r.parts, canonPart{kind: partText, text: jstr(b["text"])})
		case "tool_use":
			input := b["input"]
			if input == nil {
				input = obj{}
			}
			r.parts = append(r.parts, canonPart{kind: partToolCall, id: jstr(b["id"]), name: jstr(b["name"]), text: string(toJSON(input))})
		case "thinking":
			r.reasoning += jstr(b["thinking"])
		}
	}
	r.stop = stopFromAnthropic(jstr(j["stop_reason"]))
	r.usage = usageFromAnthropic(jobj(j["usage"]))
	return r
}

func responseFromChat(j obj) canonResponse {
	var r canonResponse
	choice := jobj(firstOf(jarr(j["choices"])))
	msg := jobj(choice["message"])
	r.reasoning = jstr(msg["reasoning_content"])
	if r.reasoning == "" {
		r.reasoning = jstr(msg["reasoning"])
	}
	if t := flattenText(msg["content"]); t != "" {
		r.parts = append(r.parts, canonPart{kind: partText, text: t})
	}
	hasCall := false
	for _, cv := range jarr(msg["tool_calls"]) {
		c := jobj(cv)
		fn := jobj(c["function"])
		args := jstr(fn["arguments"])
		if args == "" {
			args = "{}"
		}
		r.parts = append(r.parts, canonPart{kind: partToolCall, id: jstr(c["id"]), name: jstr(fn["name"]), text: args})
		hasCall = true
	}
	r.stop = stopFromChat(jstr(choice["finish_reason"]))
	if r.stop == stopEnd && hasCall {
		r.stop = stopTool
	}
	r.usage = usageFromChat(jobj(j["usage"]))
	return r
}

func firstOf(a []any) any {
	if len(a) == 0 {
		return nil
	}
	return a[0]
}

func (r canonResponse) anthropicJSON(model string) obj {
	content := []any{}
	for _, p := range r.parts {
		switch p.kind {
		case partText:
			content = append(content, obj{"type": "text", "text": p.text})
		case partToolCall:
			input := jobj(parseAny(p.text))
			if input == nil {
				input = obj{}
			}
			content = append(content, obj{"type": "tool_use", "id": toolID(p.id), "name": p.name, "input": input})
		}
	}
	return obj{"id": newID("msg_"), "type": "message", "role": "assistant", "model": model, "content": content,
		"stop_reason": r.stop.anthropic(), "stop_sequence": nil, "usage": r.usage.anthropicJSON()}
}

func (r canonResponse) chatJSON(model string, created int64) obj {
	var text strings.Builder
	var calls []any
	for _, p := range r.parts {
		switch p.kind {
		case partText:
			text.WriteString(p.text)
		case partToolCall:
			calls = append(calls, obj{"id": p.id, "type": "function", "function": obj{"name": p.name, "arguments": p.text}})
		}
	}
	msg := obj{"role": "assistant"}
	if text.Len() == 0 && len(calls) > 0 {
		msg["content"] = nil
	} else {
		msg["content"] = text.String()
	}
	if len(calls) > 0 {
		msg["tool_calls"] = calls
	}
	if r.reasoning != "" {
		msg["reasoning_content"] = r.reasoning
	}
	return obj{"id": newID("chatcmpl-"), "object": "chat.completion", "created": created, "model": model,
		"choices": []any{obj{"index": 0, "message": msg, "finish_reason": r.stop.chat()}}, "usage": r.usage.chatJSON()}
}

func (r canonResponse) responsesJSON(model string, custom map[string]bool, created int64) obj {
	var output []any
	var text strings.Builder
	for _, p := range r.parts {
		switch p.kind {
		case partText:
			text.WriteString(p.text)
		case partToolCall:
			output = append(output, responsesToolItem("", p.id, p.name, p.text, custom[p.name], "completed"))
		}
	}
	if text.Len() > 0 {
		output = append([]any{responsesMessage(newID("msg_"), text.String(), "completed")}, output...)
	}
	status := "completed"
	if r.stop == stopMax {
		status = "incomplete"
	}
	u := r.usage
	return responsesObject(newID("resp_"), model, status, output, &u, created)
}

func responsesMessage(id, text, status string) obj {
	return obj{"id": id, "type": "message", "status": status, "role": "assistant",
		"content": []any{obj{"type": "output_text", "text": text, "annotations": []any{}}}}
}

func responsesToolItem(id, callID, name, args string, custom bool, status string) obj {
	if custom {
		input := jstr(jobj(parseAny(args))["input"])
		if input == "" && jobj(parseAny(args)) == nil {
			input = args
		}
		if id == "" {
			id = newID("ctc_")
		}
		return obj{"id": id, "type": "custom_tool_call", "status": status, "call_id": callID, "name": name, "input": input}
	}
	if id == "" {
		id = newID("fc_")
	}
	return obj{"id": id, "type": "function_call", "status": status, "call_id": callID, "name": name, "arguments": args}
}

func responsesObject(id, model, status string, output []any, u *Usage, created int64) obj {
	if output == nil {
		output = []any{}
	}
	o := obj{"id": id, "object": "response", "created_at": created, "status": status, "model": model, "output": output,
		"error": nil, "incomplete_details": nil, "parallel_tool_calls": true, "tool_choice": "auto", "tools": []any{}, "usage": nil}
	if status == "incomplete" {
		o["incomplete_details"] = obj{"reason": "max_output_tokens"}
	}
	if u != nil {
		o["usage"] = u.responsesJSON()
	}
	return o
}

// --- Errors ---------------------------------------------------------------

func errorBody(api API, status int, message string) obj {
	if api == APIAnthropic {
		t := "api_error"
		switch status {
		case 400:
			t = "invalid_request_error"
		case 401:
			t = "authentication_error"
		case 403:
			t = "permission_error"
		case 404:
			t = "not_found_error"
		case 429:
			t = "rate_limit_error"
		case 529:
			t = "overloaded_error"
		}
		return obj{"type": "error", "error": obj{"type": t, "message": message}}
	}
	t := "invalid_request_error"
	if status == 401 {
		t = "invalid_api_key"
	} else if status >= 500 {
		t = "server_error"
	}
	return obj{"error": obj{"message": message, "type": t, "code": nil, "param": nil}}
}

func errorMessage(data []byte) string {
	if j := parseJSON(data); j != nil {
		if m := jstr(jobj(j["error"])["message"]); m != "" {
			return m
		}
		for _, k := range []string{"error", "message", "detail"} {
			if m := jstr(j[k]); m != "" {
				return m
			}
		}
	}
	t := strings.TrimSpace(string(data))
	if len(t) > 500 {
		t = t[:500]
	}
	if t == "" {
		return "Upstream error"
	}
	return t
}
