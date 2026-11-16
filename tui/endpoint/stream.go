package endpoint

import (
	"strings"
	"time"
)

// Upstream server-sent events are decoded into streamEvents and encoded
// as the client's API expects. Same-API streams are piped as-is.

type eventKind int

const (
	evStart eventKind = iota
	evText
	evReasoning
	evToolStart
	evToolArgs
	evFinish
	evError
)

type streamEvent struct {
	kind  eventKind
	text  string // text, reasoning, args delta, error message
	index int
	id    string
	name  string
	stop  stopReason
	usage Usage
}

// ssePayload returns the data of a "data:" line.
func ssePayload(line string) (string, bool) {
	line = strings.TrimRight(line, "\r\n")
	if !strings.HasPrefix(line, "data:") {
		return "", false
	}
	return strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "), true
}

type streamDecoder interface {
	decode(payload string) []streamEvent
	end() []streamEvent
}

type streamEncoder interface {
	encode(e streamEvent) string
}

// --- Decode Anthropic -----------------------------------------------------

type anthropicDecoder struct {
	toolIndex map[int]int
	nextTool  int
	stop      stopReason
	usage     Usage
	finished  bool
}

func newAnthropicDecoder() *anthropicDecoder { return &anthropicDecoder{toolIndex: map[int]int{}} }

func (d *anthropicDecoder) decode(payload string) []streamEvent {
	j := parseJSON([]byte(payload))
	if j == nil {
		return nil
	}
	switch jstr(j["type"]) {
	case "message_start":
		m := jobj(j["message"])
		d.usage = usageFromAnthropic(jobj(m["usage"]))
		return []streamEvent{{kind: evStart, id: jstr(m["id"]), name: jstr(m["model"]), usage: d.usage}}
	case "content_block_start":
		idx, _ := jint(j["index"])
		b := jobj(j["content_block"])
		switch jstr(b["type"]) {
		case "tool_use":
			t := d.nextTool
			d.nextTool++
			d.toolIndex[idx] = t
			return []streamEvent{{kind: evToolStart, index: t, id: jstr(b["id"]), name: jstr(b["name"])}}
		case "text":
			if t := jstr(b["text"]); t != "" {
				return []streamEvent{{kind: evText, text: t}}
			}
		}
	case "content_block_delta":
		idx, _ := jint(j["index"])
		delta := jobj(j["delta"])
		switch jstr(delta["type"]) {
		case "text_delta":
			return []streamEvent{{kind: evText, text: jstr(delta["text"])}}
		case "input_json_delta":
			if t, ok := d.toolIndex[idx]; ok {
				return []streamEvent{{kind: evToolArgs, index: t, text: jstr(delta["partial_json"])}}
			}
		case "thinking_delta":
			return []streamEvent{{kind: evReasoning, text: jstr(delta["thinking"])}}
		}
	case "message_delta":
		if s := jstr(jobj(j["delta"])["stop_reason"]); s != "" {
			d.stop = stopFromAnthropic(s)
		}
		if u := jobj(j["usage"]); u != nil {
			if o, ok := jint(u["output_tokens"]); ok {
				d.usage.Output = o
			}
			if i, ok := jint(u["input_tokens"]); ok && i > 0 {
				d.usage.Input = i
			}
		}
	case "message_stop":
		d.finished = true
		return []streamEvent{{kind: evFinish, stop: d.stop, usage: d.usage}}
	case "error":
		d.finished = true
		msg := jstr(jobj(j["error"])["message"])
		if msg == "" {
			msg = "Upstream stream error"
		}
		return []streamEvent{{kind: evError, text: msg}}
	}
	return nil
}

func (d *anthropicDecoder) end() []streamEvent {
	if d.finished {
		return nil
	}
	d.finished = true
	return []streamEvent{{kind: evFinish, stop: d.stop, usage: d.usage}}
}

// --- Decode Chat ------------------------------------------------------------

type chatDecoder struct {
	started  bool
	tools    map[int]int
	nextTool int
	stop     *stopReason
	usage    Usage
	finished bool
}

func newChatDecoder() *chatDecoder { return &chatDecoder{tools: map[int]int{}} }

func (d *chatDecoder) decode(payload string) []streamEvent {
	if strings.TrimSpace(payload) == "[DONE]" {
		return d.end()
	}
	j := parseJSON([]byte(payload))
	if j == nil {
		return nil
	}
	if e := jobj(j["error"]); e != nil {
		d.finished = true
		msg := jstr(e["message"])
		if msg == "" {
			msg = "Upstream stream error"
		}
		return []streamEvent{{kind: evError, text: msg}}
	}
	var out []streamEvent
	if !d.started {
		d.started = true
		out = append(out, streamEvent{kind: evStart, id: jstr(j["id"]), name: jstr(j["model"])})
	}
	if u := jobj(j["usage"]); u != nil {
		d.usage = usageFromChat(u)
	}
	choice := jobj(firstOf(jarr(j["choices"])))
	if choice == nil {
		return out
	}
	delta := jobj(choice["delta"])
	r := jstr(delta["reasoning_content"])
	if r == "" {
		r = jstr(delta["reasoning"])
	}
	if r != "" {
		out = append(out, streamEvent{kind: evReasoning, text: r})
	}
	if t := jstr(delta["content"]); t != "" {
		out = append(out, streamEvent{kind: evText, text: t})
	}
	for _, cv := range jarr(delta["tool_calls"]) {
		c := jobj(cv)
		raw, _ := jint(c["index"])
		fn := jobj(c["function"])
		t, known := d.tools[raw]
		if !known {
			t = d.nextTool
			d.nextTool++
			d.tools[raw] = t
			id := jstr(c["id"])
			if id == "" {
				id = newID("call_")
			}
			out = append(out, streamEvent{kind: evToolStart, index: t, id: id, name: jstr(fn["name"])})
		}
		if args := jstr(fn["arguments"]); args != "" {
			out = append(out, streamEvent{kind: evToolArgs, index: t, text: args})
		}
	}
	if f := jstr(choice["finish_reason"]); f != "" {
		s := stopFromChat(f)
		d.stop = &s
	}
	return out
}

func (d *chatDecoder) end() []streamEvent {
	if d.finished {
		return nil
	}
	d.finished = true
	s := stopEnd
	if d.stop != nil {
		s = *d.stop
	}
	if s == stopEnd && d.nextTool > 0 {
		s = stopTool
	}
	return []streamEvent{{kind: evFinish, stop: s, usage: d.usage}}
}

// --- Encode Anthropic --------------------------------------------------------

type anthropicEncoder struct {
	model    string
	started  bool
	block    int
	open     string // "", "text", "tool"
	openTool int
	sawTool  bool
}

func newAnthropicEncoder(model string) *anthropicEncoder {
	return &anthropicEncoder{model: model, block: -1}
}

func sseEvent(name string, data obj) string {
	return "event: " + name + "\ndata: " + string(toJSON(data)) + "\n\n"
}

func (e *anthropicEncoder) ensureStarted(u Usage) string {
	if e.started {
		return ""
	}
	e.started = true
	msg := obj{"id": newID("msg_"), "type": "message", "role": "assistant", "model": e.model, "content": []any{},
		"stop_reason": nil, "stop_sequence": nil,
		"usage": obj{"input_tokens": u.Input, "output_tokens": 0, "cache_read_input_tokens": u.CacheRead}}
	return sseEvent("message_start", obj{"type": "message_start", "message": msg})
}

func (e *anthropicEncoder) closeBlock() string {
	if e.open == "" {
		return ""
	}
	e.open = ""
	return sseEvent("content_block_stop", obj{"type": "content_block_stop", "index": e.block})
}

func (e *anthropicEncoder) encode(ev streamEvent) string {
	switch ev.kind {
	case evStart:
		return e.ensureStarted(ev.usage)
	case evText:
		if ev.text == "" {
			return ""
		}
		out := e.ensureStarted(Usage{})
		if e.open != "text" {
			out += e.closeBlock()
			e.block++
			e.open = "text"
			out += sseEvent("content_block_start", obj{"type": "content_block_start", "index": e.block, "content_block": obj{"type": "text", "text": ""}})
		}
		return out + sseEvent("content_block_delta", obj{"type": "content_block_delta", "index": e.block, "delta": obj{"type": "text_delta", "text": ev.text}})
	case evReasoning:
		return e.ensureStarted(Usage{})
	case evToolStart:
		out := e.ensureStarted(Usage{}) + e.closeBlock()
		e.block++
		e.open = "tool"
		e.openTool = ev.index
		e.sawTool = true
		return out + sseEvent("content_block_start", obj{"type": "content_block_start", "index": e.block,
			"content_block": obj{"type": "tool_use", "id": toolID(ev.id), "name": ev.name, "input": obj{}}})
	case evToolArgs:
		if e.open != "tool" || e.openTool != ev.index || ev.text == "" {
			return ""
		}
		return sseEvent("content_block_delta", obj{"type": "content_block_delta", "index": e.block, "delta": obj{"type": "input_json_delta", "partial_json": ev.text}})
	case evFinish:
		out := e.ensureStarted(Usage{}) + e.closeBlock()
		s := ev.stop
		if s == stopEnd && e.sawTool {
			s = stopTool
		}
		out += sseEvent("message_delta", obj{"type": "message_delta", "delta": obj{"stop_reason": s.anthropic(), "stop_sequence": nil},
			"usage": obj{"output_tokens": ev.usage.Output, "input_tokens": ev.usage.Input, "cache_read_input_tokens": ev.usage.CacheRead}})
		return out + sseEvent("message_stop", obj{"type": "message_stop"})
	case evError:
		return e.ensureStarted(Usage{}) + sseEvent("error", obj{"type": "error", "error": obj{"type": "api_error", "message": ev.text}})
	}
	return ""
}

// --- Encode Chat ---------------------------------------------------------------

type chatEncoder struct {
	model        string
	id           string
	created      int64
	includeUsage bool
	started      bool
	sawTool      bool
}

func newChatEncoder(model string, includeUsage bool) *chatEncoder {
	return &chatEncoder{model: model, id: newID("chatcmpl-"), created: time.Now().Unix(), includeUsage: includeUsage}
}

func (e *chatEncoder) chunk(delta obj, finish any) string {
	return "data: " + string(toJSON(obj{"id": e.id, "object": "chat.completion.chunk", "created": e.created, "model": e.model,
		"choices": []any{obj{"index": 0, "delta": delta, "finish_reason": finish}}})) + "\n\n"
}

func (e *chatEncoder) ensureStarted() string {
	if e.started {
		return ""
	}
	e.started = true
	return e.chunk(obj{"role": "assistant", "content": ""}, nil)
}

func (e *chatEncoder) encode(ev streamEvent) string {
	switch ev.kind {
	case evStart:
		return e.ensureStarted()
	case evText:
		if ev.text == "" {
			return ""
		}
		return e.ensureStarted() + e.chunk(obj{"content": ev.text}, nil)
	case evReasoning:
		if ev.text == "" {
			return ""
		}
		return e.ensureStarted() + e.chunk(obj{"reasoning_content": ev.text}, nil)
	case evToolStart:
		e.sawTool = true
		return e.ensureStarted() + e.chunk(obj{"tool_calls": []any{obj{"index": ev.index, "id": ev.id, "type": "function",
			"function": obj{"name": ev.name, "arguments": ""}}}}, nil)
	case evToolArgs:
		if ev.text == "" {
			return ""
		}
		return e.chunk(obj{"tool_calls": []any{obj{"index": ev.index, "function": obj{"arguments": ev.text}}}}, nil)
	case evFinish:
		s := ev.stop
		if s == stopEnd && e.sawTool {
			s = stopTool
		}
		out := e.ensureStarted() + e.chunk(obj{}, s.chat())
		if e.includeUsage {
			out += "data: " + string(toJSON(obj{"id": e.id, "object": "chat.completion.chunk", "created": e.created, "model": e.model,
				"choices": []any{}, "usage": ev.usage.chatJSON()})) + "\n\n"
		}
		return out + "data: [DONE]\n\n"
	case evError:
		return "data: " + string(toJSON(obj{"error": obj{"message": ev.text, "type": "server_error"}})) + "\n\ndata: [DONE]\n\n"
	}
	return ""
}

// --- Encode Responses ----------------------------------------------------------

type responsesEncoder struct {
	model    string
	custom   map[string]bool
	id       string
	created  int64
	seq      int
	started  bool
	output   []any
	openKind string // "", "message", "tool"
	itemID   string
	text     string
	toolIdx  int
	callID   string
	toolName string
	args     string
}

func newResponsesEncoder(model string, custom map[string]bool) *responsesEncoder {
	return &responsesEncoder{model: model, custom: custom, id: newID("resp_"), created: time.Now().Unix()}
}

func (e *responsesEncoder) event(typ string, fields obj) string {
	fields["type"] = typ
	fields["sequence_number"] = e.seq
	e.seq++
	return "event: " + typ + "\ndata: " + string(toJSON(fields)) + "\n\n"
}

func (e *responsesEncoder) snapshot(status string, u *Usage) obj {
	out := make([]any, len(e.output))
	copy(out, e.output)
	return responsesObject(e.id, e.model, status, out, u, e.created)
}

func (e *responsesEncoder) ensureStarted() string {
	if e.started {
		return ""
	}
	e.started = true
	r := e.snapshot("in_progress", nil)
	return e.event("response.created", obj{"response": r}) + e.event("response.in_progress", obj{"response": r})
}

func (e *responsesEncoder) closeItem() string {
	index := len(e.output)
	switch e.openKind {
	case "message":
		e.openKind = ""
		part := obj{"type": "output_text", "text": e.text, "annotations": []any{}}
		item := responsesMessage(e.itemID, e.text, "completed")
		e.output = append(e.output, item)
		return e.event("response.output_text.done", obj{"item_id": e.itemID, "output_index": index, "content_index": 0, "text": e.text}) +
			e.event("response.content_part.done", obj{"item_id": e.itemID, "output_index": index, "content_index": 0, "part": part}) +
			e.event("response.output_item.done", obj{"output_index": index, "item": item})
	case "tool":
		e.openKind = ""
		custom := e.custom[e.toolName]
		item := responsesToolItem(e.itemID, e.callID, e.toolName, e.args, custom, "completed")
		e.output = append(e.output, item)
		var out string
		if custom {
			out = e.event("response.custom_tool_call_input.done", obj{"item_id": e.itemID, "output_index": index, "input": jstr(item["input"])})
		} else {
			out = e.event("response.function_call_arguments.done", obj{"item_id": e.itemID, "output_index": index, "arguments": e.args})
		}
		return out + e.event("response.output_item.done", obj{"output_index": index, "item": item})
	}
	return ""
}

func (e *responsesEncoder) encode(ev streamEvent) string {
	switch ev.kind {
	case evStart, evReasoning:
		return e.ensureStarted()
	case evText:
		if ev.text == "" {
			return ""
		}
		out := e.ensureStarted()
		if e.openKind != "message" {
			out += e.closeItem()
			e.openKind = "message"
			e.itemID = newID("msg_")
			e.text = ""
			index := len(e.output)
			out += e.event("response.output_item.added", obj{"output_index": index,
				"item": obj{"id": e.itemID, "type": "message", "status": "in_progress", "role": "assistant", "content": []any{}}})
			out += e.event("response.content_part.added", obj{"item_id": e.itemID, "output_index": index, "content_index": 0,
				"part": obj{"type": "output_text", "text": "", "annotations": []any{}}})
		}
		e.text += ev.text
		return out + e.event("response.output_text.delta", obj{"item_id": e.itemID, "output_index": len(e.output), "content_index": 0, "delta": ev.text})
	case evToolStart:
		out := e.ensureStarted() + e.closeItem()
		custom := e.custom[ev.name]
		e.openKind = "tool"
		e.toolIdx = ev.index
		e.callID = ev.id
		e.toolName = ev.name
		e.args = ""
		typ, prefix, field := "function_call", "fc_", "arguments"
		if custom {
			typ, prefix, field = "custom_tool_call", "ctc_", "input"
		}
		e.itemID = newID(prefix)
		item := obj{"id": e.itemID, "type": typ, "status": "in_progress", "call_id": ev.id, "name": ev.name, field: ""}
		return out + e.event("response.output_item.added", obj{"output_index": len(e.output), "item": item})
	case evToolArgs:
		if e.openKind != "tool" || e.toolIdx != ev.index {
			return ""
		}
		e.args += ev.text
		if e.custom[e.toolName] {
			return "" // the raw input is only known once the JSON is complete
		}
		return e.event("response.function_call_arguments.delta", obj{"item_id": e.itemID, "output_index": len(e.output), "delta": ev.text})
	case evFinish:
		out := e.ensureStarted() + e.closeItem()
		status, typ := "completed", "response.completed"
		if ev.stop == stopMax {
			status, typ = "incomplete", "response.incomplete"
		}
		u := ev.usage
		return out + e.event(typ, obj{"response": e.snapshot(status, &u)})
	case evError:
		r := e.snapshot("failed", nil)
		r["error"] = obj{"code": "server_error", "message": ev.text}
		return e.ensureStarted() + e.event("error", obj{"code": "server_error", "message": ev.text, "param": nil}) +
			e.event("response.failed", obj{"response": r})
	}
	return ""
}
