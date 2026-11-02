package main

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"sync"
)

// A topic's own Codex that lives between messages: `codex app-server` over stdin and stdout (JSON-RPC). The topic's
// thread is started or resumed once; every message is a turn in it; STOP interrupts the turn. As with Claude Code,
// what Codex says between turns is read all the time and a turn it starts by itself goes to the topic.
type LiveCodex struct {
	*liveProcess
	cwd    string
	model  string
	thread string
	turn   string
	nextID int
}

var liveCodexBinary = codexBinary

func (c *LiveCodex) request(method string, params any) (int, error) {
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	c.mu.Unlock()
	return id, c.write(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
}

// waitReply reads lines until the reply to `id`; what came on the way is kept for the turn
func (c *LiveCodex) waitReply(id int) (json.RawMessage, string) {
	var kept [][]byte
	defer func() {
		c.mu.Lock()
		c.lines = append(kept, c.lines...)
		c.mu.Unlock()
	}()
	for {
		line, ok := c.Next()
		if !ok {
			return nil, c.errorText("Codex")
		}
		var r struct {
			ID     *int            `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(line, &r) == nil && r.ID != nil && *r.ID == id {
			if r.Error != nil {
				return nil, firstNonEmpty(r.Error.Message, "ошибка Codex")
			}
			return r.Result, ""
		}
		kept = append(kept, line)
	}
}

func startLiveCodex(cwd, session, model string) (*LiveCodex, string) {
	p, err := startLiveProcess(liveCodexBinary(), []string{"app-server"}, cwd)
	if err != nil {
		return nil, err.Error()
	}
	c := &LiveCodex{liveProcess: p, cwd: cwd, model: model}
	fail := func(text string) (*LiveCodex, string) {
		go c.Close()
		return nil, text
	}
	id, err := c.request("initialize", map[string]any{"clientInfo": map[string]any{"name": "telepath", "version": version}})
	if err != nil {
		return fail(err.Error())
	}
	if _, e := c.waitReply(id); e != "" {
		return fail(e)
	}
	_ = c.write(map[string]any{"jsonrpc": "2.0", "method": "initialized"})
	params := map[string]any{"cwd": cwd, "approvalPolicy": "never", "sandbox": "danger-full-access", "developerInstructions": topicPrompt}
	if model != "" {
		params["model"] = model
	}
	method := "thread/start"
	if session != "" {
		method, params["threadId"] = "thread/resume", session
	}
	if id, err = c.request(method, params); err != nil {
		return fail(err.Error())
	}
	reply, e := c.waitReply(id)
	if e != "" && session != "" {
		// the thread is gone (another computer, cleaned up): a new one
		delete(params, "threadId")
		if id, err = c.request("thread/start", params); err != nil {
			return fail(err.Error())
		}
		reply, e = c.waitReply(id)
	}
	if e != "" {
		return fail(e)
	}
	var started struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
	}
	_ = json.Unmarshal(reply, &started)
	c.thread = started.Thread.ID
	return c, ""
}

// Send starts a turn with the owner's message
func (c *LiveCodex) Send(prompt string) string {
	id, err := c.request("turn/start", map[string]any{"threadId": c.thread, "input": []any{map[string]any{"type": "text", "text": prompt}}})
	if err != nil {
		return err.Error()
	}
	reply, e := c.waitReply(id)
	if e != "" {
		return e
	}
	var r struct {
		Turn struct {
			ID string `json:"id"`
		} `json:"turn"`
	}
	_ = json.Unmarshal(reply, &r)
	c.mu.Lock()
	c.turn = r.Turn.ID
	c.mu.Unlock()
	return ""
}

type codexNote struct {
	Method string `json:"method"`
	Params struct {
		ThreadID string `json:"threadId"`
		Turn     struct {
			ID     string `json:"id"`
			Status string `json:"status"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		} `json:"turn"`
		Item struct {
			Type    string `json:"type"`
			Text    string `json:"text"`
			Command string `json:"command"`
			Query   string `json:"query"`
			Tool    string `json:"tool"`
			Changes []struct {
				Path string `json:"path"`
			} `json:"changes"`
		} `json:"item"`
	} `json:"params"`
}

// Woke: Codex began a turn by itself while the topic had none
func (c *LiveCodex) Woke() bool {
	var turn string
	woke := c.woke(func(line []byte) bool {
		var n codexNote
		_ = json.Unmarshal(line, &n)
		turn = n.Params.Turn.ID
		return n.Method == "turn/started"
	})
	if woke {
		// the turn it began, for STOP
		c.mu.Lock()
		c.turn = turn
		c.mu.Unlock()
	}
	return woke
}

// readTurn reads the turn's notifications until it completes
func (c *LiveCodex) readTurn(ev TurnEvents) (TurnResult, bool) {
	var messages []string
	for {
		line, ok := c.Next()
		if !ok {
			return TurnResult{}, false
		}
		var n codexNote
		if json.Unmarshal(line, &n) != nil || n.Method == "" {
			continue
		}
		switch n.Method {
		case "item/started":
			if ev.Step != nil {
				it := n.Params.Item
				if step := describeCodexItem(codexItemKind(it.Type), it.Command, it.Query, it.Tool, len(it.Changes) > 0); step != "" {
					if len(it.Changes) > 0 {
						step = trim("Правлю "+filepath.Base(it.Changes[0].Path), 120)
					}
					ev.Step(step)
				}
			}
		case "item/completed":
			if n.Params.Item.Type == "agentMessage" && strings.TrimSpace(n.Params.Item.Text) != "" {
				messages = append(messages, n.Params.Item.Text)
			}
		case "turn/completed":
			result := TurnResult{}
			if n.Params.Turn.Error != nil {
				result.Error = firstNonEmpty(n.Params.Turn.Error.Message, "ошибка Codex")
			} else if len(messages) > 0 {
				// the last message is the answer; earlier ones were said on the way
				result.Text = messages[len(messages)-1]
			}
			if n.Params.Turn.Status == "interrupted" {
				result.Error = ""
			}
			return result, true
		}
	}
}

// the app server names items in camelCase, `codex exec` in snake_case
func codexItemKind(kind string) string {
	var b strings.Builder
	for i, r := range kind {
		if r >= 'A' && r <= 'Z' {
			if i > 0 {
				b.WriteByte('_')
			}
			r += 'a' - 'A'
		}
		b.WriteRune(r)
	}
	return b.String()
}

// Interrupt stops the current turn; the thread goes on
func (c *LiveCodex) Interrupt() {
	c.mu.Lock()
	thread, turn := c.thread, c.turn
	c.mu.Unlock()
	if turn != "" {
		_, _ = c.request("turn/interrupt", map[string]any{"threadId": thread, "turnId": turn})
	}
}

// CodexLiveTurn is a topic's turn on its living Codex, kept by the topic between messages
type CodexLiveTurn struct {
	Model string
	mu    sync.Mutex
	live  *LiveCodex
	stop  bool
}

func (t *CodexLiveTurn) current() *LiveCodex {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.live
}

func (t *CodexLiveTurn) Run(cwd, session, prompt string, ev TurnEvents) TurnResult {
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
		started, e := startLiveCodex(cwd, session, t.Model)
		if e != "" {
			t.mu.Unlock()
			return TurnResult{Error: e}
		}
		live = started
		t.live = live
	}
	t.mu.Unlock()
	if live.thread != "" && ev.Session != nil {
		ev.Session(live.thread)
	}
	if prompt != "" {
		if e := live.Send(prompt); e != "" {
			return TurnResult{Error: e}
		}
	} else if ev.Step != nil {
		ev.Step("Работаю в фоне")
	}
	result, got := live.readTurn(ev)
	if used, max := codexContext(live.thread); max > 0 && ev.Context != nil {
		ev.Context(used, max)
	}
	if l, ok := codexLimits(); ok && ev.Limits != nil {
		ev.Limits(l)
	}
	t.mu.Lock()
	stopped := t.stop
	t.mu.Unlock()
	if stopped {
		return TurnResult{Text: "Остановил."}
	}
	if !got {
		return TurnResult{Error: live.errorText("Codex")}
	}
	return result
}

func (t *CodexLiveTurn) Stop() {
	t.mu.Lock()
	t.stop = true
	live := t.live
	t.mu.Unlock()
	if live != nil {
		live.Interrupt()
	}
}

func (t *CodexLiveTurn) Woke() bool {
	live := t.current()
	return live != nil && live.Woke()
}

func (t *CodexLiveTurn) Wake() <-chan struct{} {
	if live := t.current(); live != nil {
		return live.Notify()
	}
	return nil
}

func (t *CodexLiveTurn) Close() {
	t.mu.Lock()
	live := t.live
	t.live = nil
	t.mu.Unlock()
	if live != nil {
		live.Close()
	}
}
