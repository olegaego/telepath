package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestTopicPins(t *testing.T) {
	s := &State{path: filepath.Join(t.TempDir(), "state.json"), Topics: map[string]*TopicState{}}
	if note := s.pinsNote("a"); note != "" {
		t.Fatalf("no pins, note %q", note)
	}
	s.addPin("a", Pin{ID: 5, Text: "план релиза", Date: 1})
	s.addPin("a", Pin{ID: 7, Text: "ключи в связке", Date: 2})
	note := s.pinsNote("a")
	if !strings.Contains(note, "1. (сообщение 5") || !strings.Contains(note, "2. (сообщение 7") {
		t.Fatalf("note %q", note)
	}
	// told once: nothing new until the pins change
	if again := s.pinsNote("a"); again != "" {
		t.Fatalf("again %q", again)
	}
	s.removePin("a", 5)
	if note := s.pinsNote("a"); strings.Contains(note, "план") || !strings.Contains(note, "ключи") {
		t.Fatalf("after unpin %q", note)
	}
	s.removePin("a", 0)
	if note := s.pinsNote("a"); !strings.Contains(note, "больше нет") {
		t.Fatalf("all unpinned %q", note)
	}
	if note := s.pinsNote("b"); note != "" {
		t.Fatalf("other topic %q", note)
	}
}

func TestDraftStepsAreOneLineEach(t *testing.T) {
	text := draftText([]string{"Запускаю: ssh x 'node -e \"\n const a\"'", "Думаю"})
	for _, line := range strings.Split(text, "\n") {
		if !strings.HasPrefix(line, "✓ ") && !strings.HasPrefix(line, "… ") {
			t.Fatalf("line %q in %q", line, text)
		}
	}
}
