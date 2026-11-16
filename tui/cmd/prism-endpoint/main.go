// Command prism-endpoint runs Prism's local OpenAI/Anthropic-compatible API
// for the Windows and Linux apps (the macOS app has it built in, and
// prism-tui runs it as "prism-tui endpoint").
//
//	go build -ldflags "-X main.version=1.6.0" ./cmd/prism-endpoint
package main

import (
	"os"

	"github.com/moderniselife/prism/tui/endpoint"
)

var version = "dev"

func main() {
	os.Exit(endpoint.RunCLI(os.Args[1:], version))
}
