package main

import (
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
