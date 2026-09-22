// Command prism-tui is Prism for the terminal: list, launch, stop, create
// and delete isolated Cursor profiles without opening the app. It shares
// ~/.cursor_profiles/.profiles.json with the macOS, Windows and Linux apps.
//
// Version is stamped at release time:
//
//	go build -ldflags "-X main.version=1.2.3"
package main

import (
	"fmt"
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

var (
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

func displayVersion() string {
	return strings.TrimPrefix(version, "v")
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "--version" || os.Args[1] == "-v") {
		fmt.Printf("prism-tui %s (commit %s, built %s)\n", displayVersion(), commit, date)
		return
	}
	store, err := LoadStore()
	if err != nil {
		fmt.Fprintln(os.Stderr, "prism-tui: "+err.Error())
		os.Exit(1)
	}
	p := tea.NewProgram(newModel(store), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "prism-tui: "+err.Error())
		os.Exit(1)
	}
}
