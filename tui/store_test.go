package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestAppleEpoch(t *testing.T) {
	if got := timeToApple(time.Unix(0, 0).UTC()); got != -978307200 {
		t.Fatalf("unix 0 = %v apple seconds, want -978307200", got)
	}
	now := time.Now().UTC().Truncate(time.Second)
	if back := appleToTime(timeToApple(now)); !back.Equal(now) {
		t.Fatalf("round trip %v -> %v", now, back)
	}
}

func TestLegacyEmojiKeyIgnored(t *testing.T) {
	raw := `{"folderName":"x","displayName":"Work","emoji":"🚀","colorHex":"#FF0000",`
	raw += `"defaultMemoryMB":8192,"createdAt":778307200.0}`
	var j profileJSON
	if err := json.Unmarshal([]byte(raw), &j); err != nil {
		t.Fatal(err)
	}
	p := profileFromJSON(j)
	if p.DisplayName != "Work" || p.ColorHex != "#FF0000" || p.DefaultMemoryMB != 8192 {
		t.Fatalf("bad parse: %+v", p)
	}
	out, _ := json.Marshal(p.toJSON())
	if strings.Contains(string(out), "emoji") {
		t.Fatalf("emoji leaked into output: %s", out)
	}
}

func TestInitials(t *testing.T) {
	cases := map[string]string{"Main Cursor": "M", "  mojo layers": "M", "": "?", "   ": "?"}
	for in, want := range cases {
		if got := (Profile{DisplayName: in}).Initial(); got != want {
			t.Fatalf("initial(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSanitize(t *testing.T) {
	if got := sanitizeFolderName("a b-c_d!e+f"); got != "ab-c_def" {
		t.Fatalf("got %q", got)
	}
	if got := sanitizeFolderName("?!"); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestStripJSONComments(t *testing.T) {
	raw := "{\n// comment\n\"a\": 1, /* block */\n\"b\": [1, 2,],\n}"
	var v map[string]any
	if err := json.Unmarshal([]byte(stripJSONComments(raw)), &v); err != nil {
		t.Fatal(err)
	}
	if v["a"] != 1.0 || len(v["b"].([]any)) != 2 {
		t.Fatalf("bad merge: %v", v)
	}
}

func TestContrastingForeground(t *testing.T) {
	if contrastingForeground("#FFFFFF") != "#1A1A1A" {
		t.Fatal("white bg should get dark text")
	}
	if contrastingForeground("#000000") != "#FFFFFF" {
		t.Fatal("black bg should get light text")
	}
}
