package main

// Per-profile Cursor title bar colors: merges workbench.colorCustomizations
// into the profile's User/settings.json, preserving everything else.
// JSONC-tolerant (strips // and /* */ comments plus trailing commas),
// same as the Swift/C#/Python apps. No-op is handled by callers for the
// built-in profile — we never touch real Cursor settings.

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

func stripJSONComments(text string) string {
	var b strings.Builder
	b.Grow(len(text))
	inStr, escaped := false, false
	i := 0
	for i < len(text) {
		c := text[i]
		if inStr {
			b.WriteByte(c)
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				inStr = false
			}
			i++
			continue
		}
		if c == '"' {
			inStr = true
			b.WriteByte(c)
			i++
			continue
		}
		if c == '/' && i+1 < len(text) {
			if text[i+1] == '/' {
				for i < len(text) && text[i] != '\n' {
					i++
				}
				continue
			}
			if text[i+1] == '*' {
				i += 2
				for i < len(text) && !(text[i] == '*' && i+1 < len(text) && text[i+1] == '/') {
					i++
				}
				i += 2
				continue
			}
		}
		b.WriteByte(c)
		i++
	}
	trailingComma := regexp.MustCompile(`,\s*([}\]])`)
	out := b.String()
	for {
		loc := trailingComma.FindStringSubmatchIndex(out)
		if loc == nil {
			break
		}
		closer := out[loc[2]:loc[3]]
		out = out[:loc[0]] + closer + out[loc[1]:]
	}
	return out
}

func hexToRGB(hex string) (r, g, b float64, ok bool) {
	hex = strings.TrimPrefix(strings.TrimSpace(hex), "#")
	if len(hex) != 6 {
		return 0, 0, 0, false
	}
	v, err := strconv.ParseUint(hex, 16, 32)
	if err != nil {
		return 0, 0, 0, false
	}
	return float64((v >> 16) & 0xFF), float64((v >> 8) & 0xFF), float64(v & 0xFF), true
}

func shadeHex(hex string, factor float64) string {
	r, g, b, ok := hexToRGB(hex)
	if !ok {
		return hex
	}
	return fmt.Sprintf("#%02X%02X%02X", int(r*factor), int(g*factor), int(b*factor))
}

func contrastingForeground(hex string) string {
	r, g, b, ok := hexToRGB(hex)
	if !ok {
		return "#FFFFFF"
	}
	if 0.299*r+0.587*g+0.114*b > 150 {
		return "#1A1A1A"
	}
	return "#FFFFFF"
}

func applyTitleBarColor(profileDir, colorHex string) error {
	userDir := filepath.Join(profileDir, "User")
	if err := os.MkdirAll(userDir, 0o755); err != nil {
		return err
	}
	settingsPath := filepath.Join(userDir, "settings.json")
	settings := map[string]any{}
	if data, err := os.ReadFile(settingsPath); err == nil {
		if err := json.Unmarshal([]byte(stripJSONComments(string(data))), &settings); err != nil {
			settings = map[string]any{}
		}
	}
	colors, _ := settings["workbench.colorCustomizations"].(map[string]any)
	if colors == nil {
		colors = map[string]any{}
	}
	fg := contrastingForeground(colorHex)
	colors["titleBar.activeBackground"] = colorHex
	colors["titleBar.activeForeground"] = fg
	colors["titleBar.inactiveBackground"] = shadeHex(colorHex, 0.55)
	colors["titleBar.inactiveForeground"] = fg + "AA"
	settings["workbench.colorCustomizations"] = colors
	settings["window.titleBarStyle"] = "custom"
	data, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(settingsPath, append(data, '\n'), 0o644)
}
