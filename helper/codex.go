package main

import (
	"bufio"
	"encoding/json"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// One turn of Codex in a project folder: the official `codex exec --json`, its thread resumed, its events read line
// by line. As with Claude Code, the login stays Codex's own (ChatGPT account or API key, made in Codex itself).

type CodexTurn struct {
	mu  sync.Mutex
	cmd *exec.Cmd
}

func (t *CodexTurn) Stop() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.cmd != nil && t.cmd.Process != nil {
		_ = t.cmd.Process.Kill()
	}
}

func (t *CodexTurn) Run(cwd, session, prompt string, ev TurnEvents) TurnResult {
	flags := []string{"--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"}
	var args []string
	if session != "" {
		args = append(append([]string{"exec", "resume"}, flags...), session, prompt)
	} else {
		// Codex has no extra system prompt for exec: the topic's rules go before the first message
		args = append(append([]string{"exec"}, flags...), topicPrompt+"\n\n"+prompt)
	}
	cmd := exec.Command(codexBinary(), args...)
	cmd.Dir = cwd
	out, err := cmd.StdoutPipe()
	if err != nil {
		return TurnResult{Error: err.Error()}
	}
	var stderr strings.Builder
	cmd.Stderr = &limitedWriter{b: &stderr, max: 2000}
	t.mu.Lock()
	t.cmd = cmd
	t.mu.Unlock()
	if err := cmd.Start(); err != nil {
		return TurnResult{Error: err.Error()}
	}
	result := TurnResult{}
	var messages []string
	done := false
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		var e struct {
			Type     string `json:"type"`
			ThreadID string `json:"thread_id"`
			Message  string `json:"message"`
			Error    struct {
				Message string `json:"message"`
			} `json:"error"`
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
		}
		if json.Unmarshal(sc.Bytes(), &e) != nil {
			continue
		}
		switch e.Type {
		case "thread.started":
			if e.ThreadID != "" && ev.Session != nil {
				ev.Session(e.ThreadID)
			}
		case "item.started":
			if ev.Step != nil {
				if step := describeCodexItem(e.Item.Type, e.Item.Command, e.Item.Query, e.Item.Tool, len(e.Item.Changes) > 0); step != "" {
					if len(e.Item.Changes) > 0 {
						step = trim("Правлю "+filepath.Base(e.Item.Changes[0].Path), 120)
					}
					ev.Step(step)
				}
			}
		case "item.completed":
			if e.Item.Type == "agent_message" && strings.TrimSpace(e.Item.Text) != "" {
				messages = append(messages, e.Item.Text)
			}
		case "turn.completed":
			done = true
		case "turn.failed":
			done = true
			result.Error = firstNonEmpty(e.Error.Message, "ошибка Codex")
		case "error":
			result.Error = firstNonEmpty(e.Message, "ошибка Codex")
		}
	}
	_ = cmd.Wait()
	t.mu.Lock()
	t.cmd = nil
	t.mu.Unlock()
	if l, ok := codexLimits(); ok && ev.Limits != nil {
		ev.Limits(l)
	}
	if len(messages) > 0 && result.Error == "" {
		// the last message is the answer; earlier ones were said on the way
		result.Text = messages[len(messages)-1]
	}
	if !done && result.Error == "" && result.Text == "" {
		result.Error = firstNonEmpty(strings.TrimSpace(stderr.String()), "Codex остановился")
	}
	return result
}

func describeCodexItem(kind, command, query, tool string, changes bool) string {
	switch kind {
	case "command_execution":
		return trim("Запускаю: "+command, 80)
	case "file_change":
		return "Правлю"
	case "web_search":
		return trim(strings.TrimSpace("Ищу в интернете "+query), 120)
	case "mcp_tool_call":
		return trim(strings.TrimSpace("Работаю "+tool), 120)
	case "todo_list":
		return "Составляю план"
	case "reasoning":
		return "Думаю"
	}
	return ""
}

// Where `codex` is: on PATH, or where npm and Homebrew put it
func codexBinary() string {
	if p, err := exec.LookPath("codex"); err == nil {
		return p
	}
	for _, p := range []string{"/opt/homebrew/bin/codex", "/usr/local/bin/codex", filepath.Join(homeDir(), ".local", "bin", "codex")} {
		if fileExists(p) {
			return p
		}
	}
	return "codex"
}

func codexInstalled() bool {
	return codexBinary() != "codex"
}
