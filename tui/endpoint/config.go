// Package endpoint is Prism's local OpenAI- and Anthropic-compatible API
// for Windows, Linux and the terminal (the macOS app has its own Swift
// copy). Requests go out with the API keys of an identity — Work,
// Personal, … — so one chat can switch which account pays for it.
//
// The config file (endpoint.json) and the usage file share their format
// with the macOS app.
package endpoint

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"unicode"
)

type Provider string

const (
	Anthropic  Provider = "anthropic"
	OpenAI     Provider = "openai"
	XAI        Provider = "xai"
	Compatible Provider = "compatible"
)

var Providers = []Provider{Anthropic, OpenAI, XAI, Compatible}

func (p Provider) Label() string {
	switch p {
	case Anthropic:
		return "Anthropic"
	case OpenAI:
		return "OpenAI"
	case XAI:
		return "xAI"
	default:
		return "OpenAI-compatible"
	}
}

func (p Provider) defaultBaseURL() string {
	switch p {
	case Anthropic:
		return "https://api.anthropic.com"
	case OpenAI:
		return "https://api.openai.com/v1"
	case XAI:
		return "https://api.x.ai/v1"
	}
	return ""
}

func (p Provider) KeyRequired() bool { return p != Compatible }

type Credential struct {
	ID       string   `json:"id"`
	Provider Provider `json:"provider"`
	BaseURL  string   `json:"baseURL"`
}

// EffectiveBaseURL has no trailing slash; Anthropic's is the host root,
// the OpenAI family's ends in /v1 (added to a bare host).
func (c Credential) EffectiveBaseURL() string {
	s := strings.TrimSpace(c.BaseURL)
	if s == "" {
		s = c.Provider.defaultBaseURL()
	}
	s = strings.TrimRight(s, "/")
	if c.Provider == Anthropic {
		return strings.TrimSuffix(s, "/v1")
	}
	if u, err := url.Parse(s); err == nil && u.Host != "" && (u.Path == "" || u.Path == "/") {
		s += "/v1"
	}
	return s
}

type BudgetAction string

const (
	BudgetWarn     BudgetAction = "warn"
	BudgetFallback BudgetAction = "fallback"
	BudgetBlock    BudgetAction = "block"
)

type Identity struct {
	ID                 string       `json:"id"`
	Name               string       `json:"name"`
	ColorHex           string       `json:"colorHex"`
	Credentials        []Credential `json:"credentials"`
	DefaultModel       string       `json:"defaultModel"`
	Token              string       `json:"token"`
	FallbackIdentityID string       `json:"fallbackIdentityID,omitempty"`
	MonthlyBudget      float64      `json:"monthlyBudget,omitempty"`
	BudgetAction       BudgetAction `json:"budgetAction,omitempty"`
}

// Slug is the model prefix and @tag: "Work Stuff" → "work-stuff".
func (i Identity) Slug() string { return Slugify(i.Name) }

func Slugify(s string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
			dash = false
		} else if !dash && b.Len() > 0 {
			b.WriteByte('-')
			dash = true
		}
	}
	return strings.TrimRight(b.String(), "-")
}

func (i Identity) action() BudgetAction {
	if i.BudgetAction == "" {
		return BudgetFallback
	}
	return i.BudgetAction
}

type RuleKind string

const (
	RuleKeyword  RuleKind = "keyword"
	RuleRegex    RuleKind = "regex"
	RuleClient   RuleKind = "client"
	RuleSchedule RuleKind = "schedule"
)

type Rule struct {
	ID          string   `json:"id"`
	Enabled     bool     `json:"enabled"`
	Kind        RuleKind `json:"kind"`
	Pattern     string   `json:"pattern"`
	Days        []int    `json:"days"` // 1 = Sunday … 7 = Saturday
	StartMinute int      `json:"startMinute"`
	EndMinute   int      `json:"endMinute"`
	IdentityID  string   `json:"identityID"`
}

type Price struct {
	Input      float64 `json:"input"`
	Output     float64 `json:"output"`
	CacheRead  float64 `json:"cacheRead"`
	CacheWrite float64 `json:"cacheWrite"`
}

type Config struct {
	Enabled          bool             `json:"enabled"`
	Port             int              `json:"port"`
	AllowLAN         bool             `json:"allowLAN"`
	RequireToken     bool             `json:"requireToken"`
	Token            string           `json:"token"`
	Identities       []Identity       `json:"identities"`
	ActiveIdentityID string           `json:"activeIdentityID,omitempty"`
	TagsEnabled      bool             `json:"tagsEnabled"`
	Rules            []Rule           `json:"rules"`
	ModelList        string           `json:"modelList"` // both | prefixed | plain
	PriceOverrides   map[string]Price `json:"priceOverrides,omitempty"`
}

const DefaultPort = 4848

// Defaults matches a fresh macOS config.
func Defaults() Config {
	return Config{Port: DefaultPort, RequireToken: true, Token: NewToken(), TagsEnabled: true, ModelList: "both"}
}

func (c *Config) UnmarshalJSON(data []byte) error {
	type plain Config
	d := plain(Defaults())
	if err := json.Unmarshal(data, &d); err != nil {
		return err
	}
	*c = Config(d)
	for i := range c.Identities {
		if c.Identities[i].Token == "" {
			c.Identities[i].Token = NewToken()
		}
		if c.Identities[i].ID == "" {
			c.Identities[i].ID = NewID()
		}
	}
	for i := range c.Rules {
		if c.Rules[i].Days == nil {
			c.Rules[i].Days = []int{2, 3, 4, 5, 6}
		}
	}
	if c.Port == 0 {
		c.Port = DefaultPort
	}
	return nil
}

func (c Config) Identity(id string) *Identity {
	for i := range c.Identities {
		if c.Identities[i].ID == id {
			return &c.Identities[i]
		}
	}
	return nil
}

func (c Config) Active() *Identity {
	if id := c.Identity(c.ActiveIdentityID); id != nil {
		return id
	}
	if len(c.Identities) > 0 {
		return &c.Identities[0]
	}
	return nil
}

func NewToken() string {
	const alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 32)
	for i := range b {
		n, _ := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		b[i] = alphabet[n.Int64()]
	}
	return "prism-" + string(b)
}

func NewID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	const hex = "0123456789ABCDEF"
	out := make([]byte, 0, 36)
	for i, v := range b {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out = append(out, '-')
		}
		out = append(out, hex[v>>4], hex[v&15])
	}
	return string(out)
}

// Dir is where Prism keeps endpoint.json: the same folder as the macOS
// app on a Mac, %APPDATA%\Prism on Windows, ~/.config/prism on Linux.
func Dir() string {
	if d := os.Getenv("PRISM_ENDPOINT_DIR"); d != "" {
		return d
	}
	base, err := os.UserConfigDir()
	if err != nil {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".config")
	}
	if runtime.GOOS == "linux" {
		return filepath.Join(base, "prism")
	}
	return filepath.Join(base, "Prism")
}

func ConfigPath() string {
	if p := os.Getenv("PRISM_ENDPOINT_CONFIG"); p != "" {
		return p
	}
	return filepath.Join(Dir(), "endpoint.json")
}

func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Defaults(), nil
	}
	if err != nil {
		return Defaults(), err
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil {
		return Defaults(), err
	}
	return c, nil
}

// Save writes atomically and keeps the file private (it holds tokens).
func Save(path string, c Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ClaudeCodeEnv is the environment that sends a Claude Code profile through
// the endpoint: "" = none (the profile's own sign-in), "*" = whichever
// identity is active (main token), otherwise that identity's own token.
func ClaudeCodeEnv(identityID string) [][2]string {
	if identityID == "" {
		return nil
	}
	cfg, err := Load(ConfigPath())
	if err != nil {
		return nil
	}
	token := cfg.Token
	if identityID != "*" {
		token = ""
		for _, id := range cfg.Identities {
			if id.ID == identityID {
				token = id.Token
			}
		}
	}
	if token == "" {
		return nil
	}
	return [][2]string{
		{"ANTHROPIC_BASE_URL", "http://127.0.0.1:" + strconv.Itoa(cfg.Port)},
		{"ANTHROPIC_AUTH_TOKEN", token},
	}
}
