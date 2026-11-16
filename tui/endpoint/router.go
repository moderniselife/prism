package endpoint

import (
	"regexp"
	"sort"
	"strings"
	"time"
)

// Which identity answers, in order: an identity-prefixed model, the latest
// @tag, an identity's own token, the first matching rule, the active
// identity.

type Route struct {
	Identity   Identity
	Credential Credential
	Model      string
	Reason     string
}

type RouteError struct {
	Status  int
	Message string
}

func (e *RouteError) Error() string { return e.Message }

var autoNames = map[string]bool{"prism": true, "auto": true, "default": true, "prism-auto": true}

type modelLookup func(Credential) []string

func route(cfg Config, requested string, userTexts []string, client string, now time.Time, pinned string, known modelLookup) (Route, *RouteError) {
	if len(cfg.Identities) == 0 {
		return Route{}, &RouteError{503, "Prism has no identities yet. Add one in Prism's Endpoint settings."}
	}
	model := strings.TrimSpace(requested)
	modelSet := true
	var chosen *Identity
	reason := ""
	lower := strings.ToLower(model)

	if slash := strings.Index(lower, "/"); slash >= 0 {
		prefix := lower[:slash]
		for i := range cfg.Identities {
			if cfg.Identities[i].Slug() == prefix {
				chosen = &cfg.Identities[i]
				reason = "model prefix"
				model = model[slash+1:]
				break
			}
		}
		if chosen == nil && prefix == "prism" {
			model = model[slash+1:]
		}
	} else {
		for i := range cfg.Identities {
			if cfg.Identities[i].Slug() == lower {
				chosen = &cfg.Identities[i]
				reason = "model prefix"
				modelSet = false
			}
		}
	}
	if model == "" || autoNames[strings.ToLower(model)] {
		modelSet = false
	}

	if chosen == nil && cfg.TagsEnabled {
		for t := len(userTexts) - 1; t >= 0 && chosen == nil; t-- {
			best, bestAt := -1, -1
			for i, id := range cfg.Identities {
				if id.Slug() == "" {
					continue
				}
				if at := lastTag(id.Slug(), userTexts[t]); at > bestAt {
					best, bestAt = i, at
				}
			}
			if best >= 0 {
				chosen = &cfg.Identities[best]
				reason = "@" + chosen.Slug()
			}
		}
	}
	if chosen == nil && pinned != "" {
		if id := cfg.Identity(pinned); id != nil {
			chosen = id
			reason = id.Name + " token"
		}
	}
	if chosen == nil {
		latest := ""
		if n := len(userTexts); n > 0 {
			latest = userTexts[n-1]
		}
		for _, r := range cfg.Rules {
			if !r.Enabled {
				continue
			}
			id := cfg.Identity(r.IdentityID)
			if id != nil && ruleMatches(r, latest, client, now) {
				chosen = id
				reason = ruleReason(r)
				break
			}
		}
	}
	if chosen == nil {
		chosen = cfg.Active()
		reason = "active"
	}
	if chosen == nil {
		return Route{}, &RouteError{503, "No identity selected in Prism."}
	}
	if !modelSet {
		model = chosen.DefaultModel
	}
	if model == "" {
		return Route{}, &RouteError{400, "Pick a model, or set a default model for " + chosen.Name + " in Prism."}
	}
	cred, ok := credentialFor(model, *chosen, known)
	if !ok {
		return Route{}, &RouteError{400, chosen.Name + " has no provider for “" + model + "”. Add one in Prism's Endpoint settings."}
	}
	return Route{Identity: *chosen, Credential: cred, Model: model, Reason: reason}, nil
}

func credentialFor(model string, id Identity, known modelLookup) (Credential, bool) {
	for _, c := range id.Credentials {
		for _, m := range known(c) {
			if m == model {
				return c, true
			}
		}
	}
	if fam, ok := family(model); ok {
		for _, c := range id.Credentials {
			if c.Provider == fam {
				return c, true
			}
		}
	}
	for _, c := range id.Credentials {
		if c.Provider == Compatible {
			return c, true
		}
	}
	if len(id.Credentials) == 1 {
		return id.Credentials[0], true
	}
	return Credential{}, false
}

func family(model string) (Provider, bool) {
	m := strings.ToLower(model)
	switch {
	case strings.HasPrefix(m, "claude") || strings.Contains(m, "anthropic"):
		return Anthropic, true
	case strings.HasPrefix(m, "grok"):
		return XAI, true
	}
	for _, p := range []string{"gpt", "o1", "o3", "o4", "chatgpt", "codex", "davinci", "omni"} {
		if strings.HasPrefix(m, p) {
			return OpenAI, true
		}
	}
	return "", false
}

// --- Tags -------------------------------------------------------------------

func tagRegex(slug string) *regexp.Regexp {
	// Go's regexp has no lookbehind: match the preceding character instead.
	return regexp.MustCompile(`(?i)(^|[^\w@.])@` + regexp.QuoteMeta(slug) + `($|[^\w-])`)
}

// lastTag is the byte offset of the last "@slug" in text, or -1.
func lastTag(slug, text string) int {
	ms := tagRegex(slug).FindAllStringIndex(text, -1)
	if len(ms) == 0 {
		return -1
	}
	return ms[len(ms)-1][0]
}

func StripTags(slugs []string, text string) string {
	out := text
	for _, s := range slugs {
		if s == "" {
			continue
		}
		re := tagRegex(s)
		// Repeat: adjacent tags share a separator character.
		for i := 0; i < 4 && re.MatchString(out); i++ {
			out = re.ReplaceAllString(out, "$1$2")
		}
	}
	if out == text {
		return text
	}
	for strings.Contains(out, "  ") {
		out = strings.ReplaceAll(out, "  ", " ")
	}
	return strings.TrimSpace(out)
}

// --- Rules ----------------------------------------------------------------------

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func ruleMatches(r Rule, latest, client string, now time.Time) bool {
	p := strings.TrimSpace(r.Pattern)
	switch r.Kind {
	case RuleKeyword:
		for _, w := range splitList(p) {
			re := regexp.MustCompile(`(?i)(^|\W)` + regexp.QuoteMeta(w) + `($|\W)`)
			if re.MatchString(latest) {
				return true
			}
		}
	case RuleRegex:
		if p == "" {
			return false
		}
		re, err := regexp.Compile("(?i)" + p)
		return err == nil && re.MatchString(latest)
	case RuleClient:
		lc := strings.ToLower(client)
		for _, n := range splitList(p) {
			if strings.Contains(lc, strings.ToLower(n)) {
				return true
			}
		}
	case RuleSchedule:
		weekday := int(now.Weekday()) + 1
		found := false
		for _, d := range r.Days {
			if d == weekday {
				found = true
			}
		}
		if !found {
			return false
		}
		m := now.Hour()*60 + now.Minute()
		if r.StartMinute <= r.EndMinute {
			return m >= r.StartMinute && m < r.EndMinute
		}
		return m >= r.StartMinute || m < r.EndMinute
	}
	return false
}

func ruleReason(r Rule) string {
	switch r.Kind {
	case RuleKeyword:
		return "mentions “" + r.Pattern + "”"
	case RuleRegex:
		return "matches /" + r.Pattern + "/"
	case RuleClient:
		return "from " + r.Pattern
	}
	return "schedule"
}

// --- Model list ---------------------------------------------------------------------

func modelList(cfg Config, known modelLookup) obj {
	var data []any
	seen := map[string]bool{}
	created := time.Now().Unix()
	add := func(id, display, owner string) {
		if seen[id] {
			return
		}
		seen[id] = true
		o := obj{"id": id, "object": "model", "type": "model", "created": created, "created_at": "1970-01-01T00:00:00Z",
			"owned_by": owner, "display_name": display}
		l := strings.ToLower(id)
		if strings.Contains(l, "claude") {
			for _, tier := range []string{"opus", "sonnet", "haiku"} {
				if strings.Contains(l, tier) {
					o["anthropic_family_tier"] = tier
				}
			}
		}
		data = append(data, o)
	}
	active := cfg.Active()
	if cfg.ModelList != "prefixed" {
		name := "active"
		if active != nil {
			name = active.Name
		}
		add("prism", "Prism · "+name, "prism")
		var ordered []Identity
		if active != nil {
			ordered = append(ordered, *active)
		}
		for _, id := range cfg.Identities {
			if active == nil || id.ID != active.ID {
				ordered = append(ordered, id)
			}
		}
		for _, id := range ordered {
			for _, c := range id.Credentials {
				for _, m := range known(c) {
					add(m, m, "prism")
				}
			}
		}
	}
	if cfg.ModelList != "plain" {
		for _, id := range cfg.Identities {
			add(id.Slug(), id.Name+" · default", "prism:"+id.Slug())
			for _, c := range id.Credentials {
				for _, m := range known(c) {
					add(id.Slug()+"/"+m, id.Name+" · "+m, "prism:"+id.Slug())
				}
			}
		}
	}
	if data == nil {
		data = []any{}
	}
	out := obj{"object": "list", "data": data, "has_more": false, "first_id": nil, "last_id": nil}
	if len(data) > 0 {
		out["first_id"] = jobj(data[0])["id"]
		out["last_id"] = jobj(data[len(data)-1])["id"]
	}
	return out
}

// chatModels drops embedding, audio and image models from a provider's list.
func chatModels(ids []string, p Provider) []string {
	notChat := []string{"embed", "tts", "whisper", "dall-e", "moderation", "transcribe", "rerank"}
	skip := []string{"realtime", "audio", "image", "search", "davinci", "babbage", "sora", "computer-use"}
	var out []string
outer:
	for _, id := range ids {
		l := strings.ToLower(id)
		for _, n := range notChat {
			if strings.Contains(l, n) {
				continue outer
			}
		}
		if p == OpenAI {
			if f, ok := family(l); !ok || f != OpenAI {
				continue
			}
			for _, n := range skip {
				if strings.Contains(l, n) {
					continue outer
				}
			}
		}
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// --- User text in raw requests --------------------------------------------------------

func userTexts(body obj, api API) []string {
	var out []string
	textOf := func(content any, types map[string]bool) string {
		if s, ok := content.(string); ok {
			return s
		}
		var t []string
		for _, b := range jarr(content) {
			o := jobj(b)
			if types[jstr(o["type"])] {
				t = append(t, jstr(o["text"]))
			}
		}
		return strings.Join(t, "\n")
	}
	switch api {
	case APIAnthropic, APIChat:
		for _, mv := range jarr(body["messages"]) {
			m := jobj(mv)
			if jstr(m["role"]) == "user" {
				if t := textOf(m["content"], map[string]bool{"text": true}); t != "" {
					out = append(out, t)
				}
			}
		}
	case APIResponses:
		if s, ok := body["input"].(string); ok {
			out = append(out, s)
		}
		for _, iv := range jarr(body["input"]) {
			item := jobj(iv)
			if jstr(item["role"]) == "user" {
				if t := textOf(item["content"], map[string]bool{"input_text": true, "text": true}); t != "" {
					out = append(out, t)
				}
			}
		}
	}
	return out
}

func stripTagsIn(body obj, slugs []string, api API) {
	clean := func(content any, types map[string]bool) any {
		if s, ok := content.(string); ok {
			return StripTags(slugs, s)
		}
		arr := jarr(content)
		for i, b := range arr {
			o := jobj(b)
			if o != nil && types[jstr(o["type"])] {
				if t, ok := o["text"].(string); ok {
					o["text"] = StripTags(slugs, t)
					arr[i] = o
				}
			}
		}
		return content
	}
	switch api {
	case APIAnthropic, APIChat:
		for _, mv := range jarr(body["messages"]) {
			if m := jobj(mv); jstr(m["role"]) == "user" {
				m["content"] = clean(m["content"], map[string]bool{"text": true})
			}
		}
	case APIResponses:
		if s, ok := body["input"].(string); ok {
			body["input"] = StripTags(slugs, s)
			return
		}
		for _, iv := range jarr(body["input"]) {
			if item := jobj(iv); jstr(item["role"]) == "user" {
				item["content"] = clean(item["content"], map[string]bool{"input_text": true, "text": true})
			}
		}
	}
}

// stripReasoning drops provider-signed reasoning another account can't
// verify. Reports whether anything was removed.
func stripReasoning(body obj, api API) bool {
	removed := false
	switch api {
	case APIAnthropic:
		for _, mv := range jarr(body["messages"]) {
			m := jobj(mv)
			blocks := jarr(m["content"])
			if blocks == nil {
				continue
			}
			var kept []any
			for _, b := range blocks {
				t := jstr(jobj(b)["type"])
				if t == "thinking" || t == "redacted_thinking" {
					removed = true
					continue
				}
				kept = append(kept, b)
			}
			if len(kept) != len(blocks) {
				if len(kept) == 0 {
					kept = []any{obj{"type": "text", "text": " "}}
				}
				m["content"] = kept
			}
		}
		if removed {
			delete(body, "thinking")
		}
	case APIResponses:
		items := jarr(body["input"])
		var kept []any
		for _, it := range items {
			if jstr(jobj(it)["type"]) == "reasoning" {
				removed = true
				continue
			}
			kept = append(kept, it)
		}
		if removed {
			body["input"] = kept
		}
	}
	return removed
}
