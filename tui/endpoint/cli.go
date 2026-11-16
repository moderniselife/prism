package endpoint

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const usageText = `prism-endpoint — Prism's local OpenAI/Anthropic API that switches accounts

Usage:
  prism-endpoint serve            run the endpoint (default)
  prism-endpoint status           show identities, spend and recent requests
  prism-endpoint use <identity>   switch the active identity (name or @tag)
  prism-endpoint key <credential-id>   store an API key (read from stdin)
  prism-endpoint stop             stop a running endpoint
  prism-endpoint --version

Settings live in ` + "%s" + `
`

// RunCLI runs the endpoint command line and returns the exit code.
func RunCLI(args []string, version string) int {
	cmd := "serve"
	if len(args) > 0 {
		cmd = args[0]
	}
	path := ConfigPath()
	switch cmd {
	case "serve":
		return serve(path, version)
	case "status":
		return status(path)
	case "use":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: prism-endpoint use <identity>")
			return 2
		}
		return use(path, args[1])
	case "key":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: prism-endpoint key <credential-id>  (key on stdin)")
			return 2
		}
		key, _ := io.ReadAll(io.LimitReader(os.Stdin, 64<<10))
		k := NewKeys(Dir())
		if err := k.Set(args[1], strings.TrimSpace(string(key))); err != nil {
			fmt.Fprintln(os.Stderr, "prism-endpoint: "+err.Error())
			return 1
		}
		if k.UsingFile {
			fmt.Println("Saved (no system keyring found: stored in a private file next to the settings).")
		} else {
			fmt.Println("Saved in the system keyring.")
		}
		return 0
	case "stop":
		_, err := Admin(path, "POST", "/prism/stop", nil)
		if err != nil {
			fmt.Fprintln(os.Stderr, "prism-endpoint: "+err.Error())
			return 1
		}
		fmt.Println("Stopped.")
		return 0
	case "--version", "-v", "version":
		fmt.Println("prism-endpoint " + version)
		return 0
	default:
		fmt.Printf(usageText, path)
		if cmd == "help" || cmd == "--help" || cmd == "-h" {
			return 0
		}
		return 2
	}
}

func serve(path, version string) int {
	e := NewEngine(path)
	e.Version = version
	cfg := e.Config()
	if cfg.Token == "" || len(cfg.Identities) == 0 {
		// Make sure a token exists so apps can connect.
		if cfg.Token == "" {
			cfg.Token = NewToken()
		}
		_ = e.saveConfig(cfg)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	fmt.Printf("Prism endpoint listening on http://127.0.0.1:%d/v1 (settings: %s)\n", cfg.Port, path)
	if err := e.Serve(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "prism-endpoint: "+err.Error())
		return 1
	}
	return 0
}

// Admin calls the running endpoint's admin API with the main token.
func Admin(path, method, route string, body any) ([]byte, error) {
	cfg, err := Load(path)
	if err != nil {
		return nil, err
	}
	var rd io.Reader
	if body != nil {
		rd = strings.NewReader(string(toJSON(body)))
	}
	req, err := http.NewRequest(method, "http://127.0.0.1:"+strconv.Itoa(cfg.Port)+route, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+cfg.Token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return nil, fmt.Errorf("the endpoint isn't running (%v)", err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return data, fmt.Errorf("%s", errorMessage(data))
	}
	return data, nil
}

// FetchStatus asks a running endpoint for its status.
func FetchStatus(path string) (Status, error) {
	var st Status
	data, err := Admin(path, "GET", "/prism/status", nil)
	if err != nil {
		return st, err
	}
	err = json.Unmarshal(data, &st)
	return st, err
}

func status(path string) int {
	st, err := FetchStatus(path)
	if err != nil {
		cfg, _ := Load(path)
		fmt.Printf("Not running. %d identit%s configured in %s\n", len(cfg.Identities), plural(len(cfg.Identities), "y", "ies"), path)
		return 1
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	fmt.Fprintf(w, "Prism endpoint %s on http://127.0.0.1:%d/v1\n\n", st.Version, st.Port)
	for _, id := range st.Identities {
		mark := " "
		if id.Active {
			mark = "●"
		}
		line := fmt.Sprintf("%s %-12s @%-10s $%s this month · %d requests", mark, id.Name, id.Slug, money(id.MonthCost), id.MonthRequests)
		if id.Budget > 0 {
			line += " · budget $" + money(id.Budget)
		}
		if id.CooldownUntil != nil {
			line += " · rate-limited until " + id.CooldownUntil.Local().Format("15:04")
		}
		fmt.Fprintln(w, line)
	}
	if len(st.Log) > 0 {
		fmt.Fprintln(w, "\nRecent requests")
		for i, l := range st.Log {
			if i == 10 {
				break
			}
			fmt.Fprintf(w, "  %s  %-10s %-28s %d  %s\n", l.Date.Local().Format("15:04:05"), l.Identity, l.Model, l.Status, l.Note+l.Error)
		}
	}
	return 0
}

func use(path, name string) int {
	cfg, err := Load(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "prism-endpoint: "+err.Error())
		return 1
	}
	want := Slugify(strings.TrimPrefix(name, "@"))
	for _, id := range cfg.Identities {
		if id.Slug() == want || strings.EqualFold(id.Name, name) {
			cfg.ActiveIdentityID = id.ID
			if err := Save(path, cfg); err != nil {
				fmt.Fprintln(os.Stderr, "prism-endpoint: "+err.Error())
				return 1
			}
			_, _ = Admin(path, "POST", "/prism/reload", nil)
			fmt.Println("Now using " + id.Name + ".")
			return 0
		}
	}
	fmt.Fprintln(os.Stderr, "prism-endpoint: no identity called "+name)
	return 1
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
