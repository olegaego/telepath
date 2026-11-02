package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// A topic's own Claude Code that lives between messages: `claude -p` with stream-json in and out. Messages go to it
// one after another, so a long session is not read again for every answer. Its output is read all the time: when
// Claude starts a turn by itself (its background task finished), that turn is not lost and is not taken for the
// answer to the next message.
type LiveClaude struct {
	mu      sync.Mutex
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	lines   [][]byte
	ended   bool          // the process closed its output
	notify  chan struct{} // a line came or the output ended
	stderr  *strings.Builder
	cwd     string
	model   string
	stopped int
}

// How long a closed process may take to exit before it is killed
const liveCloseWait = 10 * time.Second

var liveClaudeBinary = claudeBinary

func liveClaudeArgs(session, model string) []string {
	args := []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
		"--permission-mode", "bypassPermissions", "--append-system-prompt", topicPrompt}
	if session != "" {
		args = append(args, "--resume", session)
	}
	if model != "" {
		args = append(args, "--model", model)
	}
	return args
}

func startLiveClaude(cwd, session, model string) (*LiveClaude, error) {
	cmd := exec.Command(liveClaudeBinary(), liveClaudeArgs(session, model)...)
	cmd.Dir = cwd
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	var stderr strings.Builder
	cmd.Stderr = &limitedWriter{b: &stderr, max: 2000}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	l := &LiveClaude{cmd: cmd, stdin: stdin, notify: make(chan struct{}, 1), stderr: &stderr, cwd: cwd, model: model}
	go l.read(out)
	return l, nil
}

func (l *LiveClaude) read(out io.Reader) {
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		line := append([]byte(nil), sc.Bytes()...)
		l.mu.Lock()
		l.lines = append(l.lines, line)
		l.mu.Unlock()
		l.poke()
	}
	l.mu.Lock()
	l.ended = true
	l.mu.Unlock()
	l.poke()
	_ = l.cmd.Wait()
}

func (l *LiveClaude) poke() {
	select {
	case l.notify <- struct{}{}:
	default:
	}
}

// Notify fires when a line comes or the output ends
func (l *LiveClaude) Notify() <-chan struct{} {
	return l.notify
}

// Alive: the process still has its output open
func (l *LiveClaude) Alive() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return !l.ended
}

// Send gives Claude the owner's message, as if typed in its session
func (l *LiveClaude) Send(prompt string) error {
	msg := map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": prompt}}
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	_, err = l.stdin.Write(append(data, '\n'))
	return err
}

// Next waits for the next line; false once the output ended and every line was taken
func (l *LiveClaude) Next() ([]byte, bool) {
	for {
		l.mu.Lock()
		if len(l.lines) > 0 {
			line := l.lines[0]
			l.lines = l.lines[1:]
			l.mu.Unlock()
			return line, true
		}
		ended := l.ended
		l.mu.Unlock()
		if ended {
			return nil, false
		}
		<-l.notify
	}
}

// Woke: between turns Claude started one by itself. Lines that are not part of a turn are dropped.
func (l *LiveClaude) Woke() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for len(l.lines) > 0 {
		var e struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(l.lines[0], &e)
		switch e.Type {
		case "stream_event", "assistant", "user", "result":
			return true
		}
		l.lines = l.lines[1:]
	}
	return false
}

// Interrupt stops the current turn; the process and its conversation stay
func (l *LiveClaude) Interrupt() {
	l.mu.Lock()
	l.stopped++
	n := l.stopped
	l.mu.Unlock()
	req := fmt.Sprintf(`{"type":"control_request","request_id":"stop%d","request":{"subtype":"interrupt"}}`, n)
	l.mu.Lock()
	_, _ = l.stdin.Write([]byte(req + "\n"))
	l.mu.Unlock()
}

// Close lets the process end by itself, then kills it
func (l *LiveClaude) Close() {
	l.mu.Lock()
	_ = l.stdin.Close()
	l.mu.Unlock()
	deadline := time.After(liveCloseWait)
	for l.Alive() {
		select {
		case <-l.notify:
		case <-deadline:
			if l.cmd.Process != nil {
				_ = l.cmd.Process.Kill()
			}
			return
		}
	}
}

func (l *LiveClaude) errorText() string {
	return firstNonEmpty(strings.TrimSpace(l.stderr.String()), "Claude Code остановился")
}

// ClaudeLiveTurn is a topic's turn on its living Claude Code. The topic keeps it between messages; an empty prompt
// reads the turn Claude started by itself.
type ClaudeLiveTurn struct {
	Model string
	mu    sync.Mutex
	live  *LiveClaude
	stop  bool
}

func (t *ClaudeLiveTurn) current() *LiveClaude {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.live
}

func (t *ClaudeLiveTurn) Run(cwd, session, prompt string, ev TurnEvents) TurnResult {
	t.mu.Lock()
	t.stop = false
	live := t.live
	if live != nil && (!live.Alive() || live.cwd != cwd) {
		go live.Close()
		live = nil
	}
	if live == nil {
		if prompt == "" {
			t.mu.Unlock()
			return TurnResult{}
		}
		started, err := startLiveClaude(cwd, session, t.Model)
		if err != nil {
			t.mu.Unlock()
			return TurnResult{Error: err.Error()}
		}
		live = started
		t.live = live
	}
	t.mu.Unlock()
	if prompt != "" {
		if err := live.Send(prompt); err != nil {
			return TurnResult{Error: err.Error()}
		}
	} else if ev.Step != nil {
		ev.Step("Работаю в фоне")
	}
	result, got := readClaudeTurn(live.Next, ev)
	t.mu.Lock()
	stopped := t.stop
	t.mu.Unlock()
	if stopped {
		return TurnResult{Text: "Остановил."}
	}
	if !got {
		return TurnResult{Error: live.errorText()}
	}
	return result
}

// Stop interrupts the turn; the conversation goes on with the next message
func (t *ClaudeLiveTurn) Stop() {
	t.mu.Lock()
	t.stop = true
	live := t.live
	t.mu.Unlock()
	if live != nil {
		live.Interrupt()
	}
}

// Woke: Claude began a turn by itself while the topic had none
func (t *ClaudeLiveTurn) Woke() bool {
	live := t.current()
	return live != nil && live.Woke()
}

// Wake fires when Claude prints something; nil while there is no process
func (t *ClaudeLiveTurn) Wake() <-chan struct{} {
	if live := t.current(); live != nil {
		return live.Notify()
	}
	return nil
}

// Close ends the process; the next message starts it again with --resume
func (t *ClaudeLiveTurn) Close() {
	t.mu.Lock()
	live := t.live
	t.live = nil
	t.mu.Unlock()
	if live != nil {
		live.Close()
	}
}
