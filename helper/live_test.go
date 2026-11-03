package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// The test binary plays Claude Code when FAKE_CLAUDE is set: a message «X» is answered «ответ: X»; «фон» also ends a
// background task a moment later, as a turn of its own; «долго» waits for an interrupt
func TestMain(m *testing.M) {
	if os.Getenv("FAKE_CLAUDE") == "1" {
		fakeClaude()
		os.Exit(0)
	}
	if os.Getenv("FAKE_CODEX") == "1" {
		fakeCodex()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func fakeClaude() {
	out := func(v map[string]any) {
		data, _ := json.Marshal(v)
		fmt.Println(string(data))
	}
	answer := func(text string) {
		out(map[string]any{"type": "system", "subtype": "init", "session_id": "s1", "model": "claude-test"})
		out(map[string]any{"type": "assistant", "message": map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}}})
		out(map[string]any{"type": "result", "result": text, "session_id": "s1"})
	}
	waiting := false
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		var m struct {
			Type    string `json:"type"`
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		}
		_ = json.Unmarshal(sc.Bytes(), &m)
		switch {
		case m.Type == "control_request":
			if waiting {
				waiting = false
				out(map[string]any{"type": "result", "is_error": true, "subtype": "error_during_execution", "session_id": "s1"})
			}
		case m.Message.Content == "долго":
			waiting = true
			out(map[string]any{"type": "assistant", "message": map[string]any{"content": []any{map[string]any{"type": "tool_use", "name": "Bash", "input": map[string]any{"command": "sleep 100"}}}}})
		case m.Message.Content == "фото":
			answer("смотри\n\n[[фото: p.png]]")
		default:
			answer("ответ: " + m.Message.Content)
			if m.Message.Content == "фон" {
				go func() {
					time.Sleep(300 * time.Millisecond)
					answer("фон готов")
				}()
			}
		}
	}
}

func fakeLive(t *testing.T) *ClaudeLiveTurn {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_CLAUDE", "1")
	old := liveClaudeBinary
	liveClaudeBinary = func() string { return exe }
	t.Cleanup(func() { liveClaudeBinary = old })
	turn := &ClaudeLiveTurn{}
	t.Cleanup(turn.Close)
	return turn
}

func waitWoke(t *testing.T, turn *ClaudeLiveTurn) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !turn.Woke() {
		if time.Now().After(deadline) {
			t.Fatal("Claude did not start its own turn")
		}
		select {
		case <-turn.Wake():
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func TestLiveKeepsOneProcess(t *testing.T) {
	turn := fakeLive(t)
	dir := t.TempDir()
	if r := turn.Run(dir, "", "привет", TurnEvents{}); r.Text != "ответ: привет" {
		t.Fatalf("first answer %+v", r)
	}
	first := turn.current()
	if r := turn.Run(dir, "s1", "ещё", TurnEvents{}); r.Text != "ответ: ещё" {
		t.Fatalf("second answer %+v", r)
	}
	if turn.current() != first {
		t.Fatal("the second message started a new process")
	}
}

func TestLiveBackgroundTurnComesByItself(t *testing.T) {
	turn := fakeLive(t)
	dir := t.TempDir()
	if r := turn.Run(dir, "", "фон", TurnEvents{}); r.Text != "ответ: фон" {
		t.Fatalf("answer %+v", r)
	}
	waitWoke(t, turn)
	var steps []string
	if r := turn.Run(dir, "s1", "", TurnEvents{Step: func(s string) { steps = append(steps, s) }}); r.Text != "фон готов" {
		t.Fatalf("background turn %+v", r)
	}
	if len(steps) == 0 || steps[0] != "Работаю в фоне" {
		t.Fatalf("steps %v", steps)
	}
	// the next message gets its own answer, not the background one
	if r := turn.Run(dir, "s1", "второе", TurnEvents{}); r.Text != "ответ: второе" {
		t.Fatalf("next answer %+v", r)
	}
}

func TestLiveStopKeepsTheConversation(t *testing.T) {
	turn := fakeLive(t)
	dir := t.TempDir()
	done := make(chan TurnResult)
	go func() { done <- turn.Run(dir, "", "долго", TurnEvents{}) }()
	time.Sleep(300 * time.Millisecond)
	process := turn.current()
	turn.Stop()
	select {
	case r := <-done:
		if r.Text != "Остановил." {
			t.Fatalf("stopped turn %+v", r)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the turn did not stop")
	}
	if r := turn.Run(dir, "s1", "дальше", TurnEvents{}); r.Text != "ответ: дальше" {
		t.Fatalf("after stop %+v", r)
	}
	if turn.current() != process {
		t.Fatal("stop killed the process")
	}
}

func TestLiveStartsAgainAfterItDied(t *testing.T) {
	turn := fakeLive(t)
	dir := t.TempDir()
	turn.Run(dir, "", "раз", TurnEvents{})
	dead := turn.current()
	_ = dead.cmd.Process.Kill()
	for dead.Alive() {
		<-dead.Notify()
	}
	if r := turn.Run(dir, "s1", "два", TurnEvents{}); r.Text != "ответ: два" {
		t.Fatalf("after death %+v", r)
	}
	if turn.current() == dead {
		t.Fatal("still the dead process")
	}
}

func TestLiveResumesTheSession(t *testing.T) {
	args := strings.Join(liveClaudeArgs("abc", "opus"), " ")
	if !strings.Contains(args, "--resume abc") || !strings.Contains(args, "--model opus") || !strings.Contains(args, "--input-format stream-json") {
		t.Fatalf("args %s", args)
	}
}

// The whole topic: an answer, then the background task's message by itself, then the next message's own answer
func TestTopicSendsBackgroundTurnByItself(t *testing.T) {
	fakeLive(t)
	t.Setenv("HOME", t.TempDir())
	sent := make(chan string, 16)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		method := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		if method == "sendRichMessage" || method == "sendMessage" {
			body, _ := io.ReadAll(r.Body)
			text := r.Form.Get("text") + string(body)
			for _, want := range []string{"ответ: фон", "фон готов", "ответ: второе"} {
				if strings.Contains(text, want) {
					sent <- want
				}
			}
		}
		_, _ = w.Write([]byte(`{"ok":true,"result":{"message_id":1}}`))
	}))
	t.Cleanup(api.Close)
	old := botAPI
	botAPI = api.URL
	t.Cleanup(func() { botAPI = old })
	h := &Helper{cfg: Config{BotToken: "1:x", BotName: "test", Engine: "claude"}, bot: NewBot("1:x"), state: loadState("test"), topics: map[string]*topicWork{}, pending: map[string]*pendingChoice{}}
	h.board, h.drafts = newStatusBoard(), newDraftBudget()
	t.Cleanup(h.closeTopics)
	dir := t.TempDir()
	key := topicKey(1, 2)
	h.state.setTopic(key, TopicState{Cwd: dir})
	expect := func(want string) {
		t.Helper()
		select {
		case got := <-sent:
			if got != want {
				t.Fatalf("sent %q, want %q", got, want)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("%q did not come", want)
		}
	}
	h.enqueue(1, 2, TopicState{Cwd: dir}, "фон")
	expect("ответ: фон")
	expect("фон готов")
	h.enqueue(1, 2, TopicState{Cwd: dir}, "второе")
	expect("ответ: второе")
}

// A quiet topic lets its engine go; the next message starts it again
func TestQuietTopicClosesItsEngine(t *testing.T) {
	fakeLive(t)
	t.Setenv("HOME", t.TempDir())
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"ok":true,"result":{"message_id":1}}`))
	}))
	t.Cleanup(api.Close)
	old, oldIdle := botAPI, liveIdle
	botAPI, liveIdle = api.URL, 300*time.Millisecond
	t.Cleanup(func() { botAPI, liveIdle = old, oldIdle })
	h := &Helper{cfg: Config{BotToken: "1:x", BotName: "test", Engine: "claude"}, bot: NewBot("1:x"), state: loadState("test"), topics: map[string]*topicWork{}, pending: map[string]*pendingChoice{}}
	h.board, h.drafts = newStatusBoard(), newDraftBudget()
	dir := t.TempDir()
	h.state.setTopic(topicKey(1, 2), TopicState{Cwd: dir})
	h.enqueue(1, 2, TopicState{Cwd: dir}, "раз")
	deadline := time.Now().Add(5 * time.Second)
	for {
		h.mu.Lock()
		_, open := h.topics[topicKey(1, 2)]
		h.mu.Unlock()
		if !open {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the quiet topic kept its engine")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// Pictures in an answer go to the topic as a photo before the text
func TestTopicSendsPhotos(t *testing.T) {
	fakeLive(t)
	t.Setenv("HOME", t.TempDir())
	calls := make(chan string, 16)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls <- r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		_, _ = w.Write([]byte(`{"ok":true,"result":{"message_id":1}}`))
	}))
	t.Cleanup(api.Close)
	old := botAPI
	botAPI = api.URL
	t.Cleanup(func() { botAPI = old })
	h := &Helper{cfg: Config{BotToken: "1:x", BotName: "test", Engine: "claude"}, bot: NewBot("1:x"), state: loadState("test"), topics: map[string]*topicWork{}, pending: map[string]*pendingChoice{}}
	h.board, h.drafts = newStatusBoard(), newDraftBudget()
	t.Cleanup(h.closeTopics)
	dir := t.TempDir()
	_ = os.WriteFile(dir+"/p.png", []byte("png"), 0o644)
	h.state.setTopic(topicKey(1, 2), TopicState{Cwd: dir})
	h.enqueue(1, 2, TopicState{Cwd: dir}, "фото")
	deadline := time.After(5 * time.Second)
	photo := false
	for {
		select {
		case c := <-calls:
			if c == "sendPhoto" {
				photo = true
			}
			if c == "sendRichMessage" {
				if !photo {
					t.Fatal("the text came before the photo")
				}
				return
			}
		case <-deadline:
			t.Fatal("no answer")
		}
	}
}

// A living process says its 1M model once; later turns keep that window, not 200k
func TestLiveKeepsTheContextWindow(t *testing.T) {
	window := 0
	lines := func(items ...string) func() ([]byte, bool) {
		return func() ([]byte, bool) {
			if len(items) == 0 {
				return nil, false
			}
			line := items[0]
			items = items[1:]
			return []byte(line), true
		}
	}
	var max int
	ev := TurnEvents{Context: func(used, m int) { max = m }}
	readClaudeTurn(lines(`{"type":"system","subtype":"init","model":"claude-opus-4[1m]"}`, `{"type":"assistant","message":{"usage":{"input_tokens":900000}}}`, `{"type":"result","result":"a"}`), ev, &window)
	readClaudeTurn(lines(`{"type":"assistant","message":{"usage":{"input_tokens":922000}}}`, `{"type":"result","result":"b"}`), ev, &window)
	if max != 1000000 {
		t.Fatalf("window %d, want 1000000", max)
	}
}
