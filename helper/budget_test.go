package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// One chat gets a draft at most every 1.5 s whatever the number of topics, and none while Telegram asked to wait
func TestDraftBudget(t *testing.T) {
	b := newDraftBudget()
	if !b.take(1) || b.take(1) {
		t.Fatal("second draft within 1.5 s must wait")
	}
	if !b.take(2) {
		t.Fatal("another chat has its own budget")
	}
	b.next[1] = time.Now().Add(-time.Second)
	b.obey(1, &APIError{RetryAfter: 30})
	if b.take(1) {
		t.Fatal("retry_after must hold drafts")
	}
	if got := draftText([]string{"a", "b", "c"}); got != "✓ a\n✓ b\n… c" {
		t.Fatalf("draft: %q", got)
	}
}

// The draft's limits line, and Codex's numbers read from its files without using up the 80% warning
func TestDraftLimitsAndCodexRefresh(t *testing.T) {
	if got := draftLimitsLine("codex", EngineLimits{}); got != "" {
		t.Fatalf("no windows, no line: %q", got)
	}
	got := draftLimitsLine("claude", EngineLimits{Time: 100, Windows: []LimitWindow{{Name: "5h", Percent: 96.6, ResetsAt: 200}, {Name: "week", Percent: 40, ResetsAt: 300}}})
	if got != "✓ limits claude 100 5h=97:200 week=40:300" {
		t.Fatalf("line: %q", got)
	}

	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	dir := filepath.Join(home, ".codex", "sessions")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dataDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "a.jsonl")
	write := func(pct int, when time.Time) {
		line := fmt.Sprintf(`{"payload":{"rate_limits":{"primary":{"used_percent":%d,"window_minutes":300,"resets_at":999}}}}`, pct)
		if err := os.WriteFile(file, []byte(line+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(file, when, when); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-time.Hour).Truncate(time.Second)
	write(93, old)
	refreshCodexLimits()
	l := allLimits()["codex"]
	if len(l.Windows) != 1 || l.Windows[0].Percent != 93 || l.Time != old.Unix() {
		t.Fatalf("refresh: %+v", l)
	}
	// a turn's numbers are newer than the file: the file does not take them back
	if warn := saveLimits("codex", EngineLimits{Windows: []LimitWindow{{Name: "5h", Percent: 50, ResetsAt: 999}}}); len(warn) != 0 {
		t.Fatalf("no warning under 80%%: %+v", warn)
	}
	refreshCodexLimits()
	if l := allLimits()["codex"]; l.Windows[0].Percent != 50 {
		t.Fatalf("old file won: %+v", l)
	}
	// work outside the helper: fresh numbers, and the next turn still warns about 97%
	write(97, time.Now().Add(time.Minute))
	refreshCodexLimits()
	if l := allLimits()["codex"]; l.Windows[0].Percent != 97 {
		t.Fatalf("new file lost: %+v", l)
	}
	if warn := saveLimits("codex", EngineLimits{Windows: []LimitWindow{{Name: "5h", Percent: 97, ResetsAt: 999}}}); len(warn) != 1 {
		t.Fatalf("the warning must wait for the turn: %+v", warn)
	}
}

func TestShortTokens(t *testing.T) {
	for n, want := range map[int]string{0: "0", 999: "999", 3210: "3.2k", 10400: "10k", 182600: "183k", 1000000: "1M", 1500000: "1.5M"} {
		if got := shortTokens(n); got != want {
			t.Fatalf("%d: %q", n, got)
		}
	}
}

// A network error must not carry the bot's token into the log
func TestNetworkErrorHidesToken(t *testing.T) {
	old := botAPI
	botAPI = "http://127.0.0.1:1"
	defer func() { botAPI = old }()
	_, err := NewBot("123:SECRET").GetMe()
	if err == nil || strings.Contains(err.Error(), "SECRET") {
		t.Fatalf("token in error: %v", err)
	}
}
