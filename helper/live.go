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

// An engine's process that lives between a topic's messages: lines in on stdin, lines out read all the time into a
// buffer, so what it says between turns is not lost. Claude Code and Codex both run on it.
type liveProcess struct {
	mu     sync.Mutex
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	lines  [][]byte
	ended  bool          // the process closed its output
	notify chan struct{} // a line came or the output ended
	stderr *strings.Builder
}

// How long a closed process may take to exit before it is killed
const liveCloseWait = 10 * time.Second

func startLiveProcess(binary string, args []string, cwd string) (*liveProcess, error) {
	cmd := exec.Command(binary, args...)
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
	p := &liveProcess{cmd: cmd, stdin: stdin, notify: make(chan struct{}, 1), stderr: &stderr}
	go p.read(out)
	return p, nil
}

func (p *liveProcess) read(out io.Reader) {
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		line := append([]byte(nil), sc.Bytes()...)
		p.mu.Lock()
		p.lines = append(p.lines, line)
		p.mu.Unlock()
		p.poke()
	}
	p.mu.Lock()
	p.ended = true
	p.mu.Unlock()
	p.poke()
	_ = p.cmd.Wait()
}

func (p *liveProcess) poke() {
	select {
	case p.notify <- struct{}{}:
	default:
	}
}

// Notify fires when a line comes or the output ends
func (p *liveProcess) Notify() <-chan struct{} {
	return p.notify
}

// Alive: the process still has its output open
func (p *liveProcess) Alive() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return !p.ended
}

// write sends one line to the process
func (p *liveProcess) write(v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	_, err = p.stdin.Write(append(data, '\n'))
	return err
}

// Next waits for the next line; false once the output ended and every line was taken
func (p *liveProcess) Next() ([]byte, bool) {
	for {
		p.mu.Lock()
		if len(p.lines) > 0 {
			line := p.lines[0]
			p.lines = p.lines[1:]
			p.mu.Unlock()
			return line, true
		}
		ended := p.ended
		p.mu.Unlock()
		if ended {
			return nil, false
		}
		<-p.notify
	}
}

// woke keeps the lines from the first one `starts` says begins a turn; lines before it are dropped
func (p *liveProcess) woke(starts func(line []byte) bool) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for len(p.lines) > 0 {
		if starts(p.lines[0]) {
			return true
		}
		p.lines = p.lines[1:]
	}
	return false
}

// Close lets the process end by itself, then kills it
func (p *liveProcess) Close() {
	p.mu.Lock()
	_ = p.stdin.Close()
	p.mu.Unlock()
	deadline := time.After(liveCloseWait)
	for p.Alive() {
		select {
		case <-p.notify:
		case <-deadline:
			if p.cmd.Process != nil {
				_ = p.cmd.Process.Kill()
			}
			return
		}
	}
}

func (p *liveProcess) errorText(engine string) string {
	return firstNonEmpty(strings.TrimSpace(p.stderr.String()), engine+" остановился")
}

// A topic's own Claude Code: `claude -p` with stream-json in and out
type LiveClaude struct {
	*liveProcess
	cwd     string
	model   string
	stopped int
	window  int // the session's context window, learned at the start and from each result
}

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
	p, err := startLiveProcess(liveClaudeBinary(), liveClaudeArgs(session, model), cwd)
	if err != nil {
		return nil, err
	}
	return &LiveClaude{liveProcess: p, cwd: cwd, model: model}, nil
}

// Send gives Claude the owner's message, as if typed in its session
func (l *LiveClaude) Send(prompt string) error {
	return l.write(map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": prompt}})
}

// Woke: between turns Claude started one by itself. Lines that are not part of a turn are dropped.
func (l *LiveClaude) Woke() bool {
	return l.woke(func(line []byte) bool {
		var e struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(line, &e)
		switch e.Type {
		case "stream_event", "assistant", "user", "result":
			return true
		}
		return false
	})
}

// Interrupt stops the current turn; the process and its conversation stay
func (l *LiveClaude) Interrupt() {
	l.mu.Lock()
	l.stopped++
	n := l.stopped
	l.mu.Unlock()
	_ = l.write(map[string]any{"type": "control_request", "request_id": fmt.Sprintf("stop%d", n), "request": map[string]any{"subtype": "interrupt"}})
}

func (l *LiveClaude) errorText() string {
	return l.liveProcess.errorText("Claude Code")
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
	result, got := readClaudeTurn(live.Next, ev, &live.window)
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
