package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"
)

// The test binary plays `codex app-server` when FAKE_CODEX is set, the same way fakeClaude plays Claude Code
func fakeCodex() {
	var mu sync.Mutex
	out := func(v map[string]any) {
		mu.Lock()
		defer mu.Unlock()
		data, _ := json.Marshal(v)
		fmt.Println(string(data))
	}
	note := func(method string, params map[string]any) {
		out(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
	}
	turn := func(id, text string) {
		note("turn/started", map[string]any{"threadId": "t1", "turn": map[string]any{"id": id, "status": "inProgress"}})
		note("item/started", map[string]any{"threadId": "t1", "item": map[string]any{"type": "commandExecution", "command": "ls"}})
		note("item/completed", map[string]any{"threadId": "t1", "item": map[string]any{"type": "agentMessage", "text": text}})
		note("turn/completed", map[string]any{"threadId": "t1", "turn": map[string]any{"id": id, "status": "completed"}})
	}
	waiting := ""
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		var m struct {
			ID     int    `json:"id"`
			Method string `json:"method"`
			Params struct {
				Input []struct {
					Text string `json:"text"`
				} `json:"input"`
			} `json:"params"`
		}
		_ = json.Unmarshal(sc.Bytes(), &m)
		reply := func(result map[string]any) {
			out(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": result})
		}
		switch m.Method {
		case "initialize":
			reply(map[string]any{"userAgent": "fake"})
		case "thread/start", "thread/resume":
			reply(map[string]any{"thread": map[string]any{"id": "t1"}})
		case "turn/start":
			text := m.Params.Input[0].Text
			id := fmt.Sprintf("u%d", m.ID)
			reply(map[string]any{"turn": map[string]any{"id": id}})
			switch text {
			case "долго":
				waiting = id
				note("turn/started", map[string]any{"threadId": "t1", "turn": map[string]any{"id": id}})
			case "фон":
				turn(id, "ответ: фон")
				go func() {
					time.Sleep(300 * time.Millisecond)
					turn("bg", "фон готов")
				}()
			default:
				turn(id, "ответ: "+text)
			}
		case "turn/interrupt":
			reply(map[string]any{})
			if waiting != "" {
				note("turn/completed", map[string]any{"threadId": "t1", "turn": map[string]any{"id": waiting, "status": "interrupted"}})
				waiting = ""
			}
		}
	}
}

func fakeLiveCodex(t *testing.T) *CodexLiveTurn {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_CODEX", "1")
	t.Setenv("HOME", t.TempDir())
	old := liveCodexBinary
	liveCodexBinary = func() string { return exe }
	t.Cleanup(func() { liveCodexBinary = old })
	turn := &CodexLiveTurn{}
	t.Cleanup(turn.Close)
	return turn
}

func TestLiveCodexKeepsOneProcess(t *testing.T) {
	turn := fakeLiveCodex(t)
	dir := t.TempDir()
	var session string
	var steps []string
	r := turn.Run(dir, "", "привет", TurnEvents{Session: func(id string) { session = id }, Step: func(s string) { steps = append(steps, s) }})
	if r.Text != "ответ: привет" || session != "t1" || len(steps) == 0 {
		t.Fatalf("first answer %+v, session %q, steps %v", r, session, steps)
	}
	first := turn.current()
	if r := turn.Run(dir, "t1", "ещё", TurnEvents{}); r.Text != "ответ: ещё" {
		t.Fatalf("second answer %+v", r)
	}
	if turn.current() != first {
		t.Fatal("the second message started a new process")
	}
}

func TestLiveCodexBackgroundTurnComesByItself(t *testing.T) {
	turn := fakeLiveCodex(t)
	dir := t.TempDir()
	if r := turn.Run(dir, "", "фон", TurnEvents{}); r.Text != "ответ: фон" {
		t.Fatalf("answer %+v", r)
	}
	deadline := time.Now().Add(3 * time.Second)
	for !turn.Woke() {
		if time.Now().After(deadline) {
			t.Fatal("Codex did not start its own turn")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if r := turn.Run(dir, "t1", "", TurnEvents{}); r.Text != "фон готов" {
		t.Fatalf("background turn %+v", r)
	}
	if r := turn.Run(dir, "t1", "второе", TurnEvents{}); r.Text != "ответ: второе" {
		t.Fatalf("next answer %+v", r)
	}
}

func TestLiveCodexStop(t *testing.T) {
	turn := fakeLiveCodex(t)
	dir := t.TempDir()
	done := make(chan TurnResult)
	go func() { done <- turn.Run(dir, "", "долго", TurnEvents{}) }()
	time.Sleep(300 * time.Millisecond)
	turn.Stop()
	select {
	case r := <-done:
		if r.Text != "Остановил." {
			t.Fatalf("stopped turn %+v", r)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the turn did not stop")
	}
	if r := turn.Run(dir, "t1", "дальше", TurnEvents{}); r.Text != "ответ: дальше" {
		t.Fatalf("after stop %+v", r)
	}
}
