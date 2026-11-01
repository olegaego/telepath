package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// One turn of Codex in a project folder: the official `codex exec --json`, its thread resumed, its events read line
// by line. As with Claude Code, the login stays Codex's own (ChatGPT account or API key, made in Codex itself).

type CodexTurn struct {
	engineProcess
	Model string
}

func (t *CodexTurn) Run(cwd, session, prompt string, ev TurnEvents) TurnResult {
	flags := []string{"--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"}
	if t.Model != "" {
		flags = append(flags, "-m", t.Model)
	}
	var args []string
	if session != "" {
		args = append(append([]string{"exec", "resume"}, flags...), session, prompt)
	} else {
		// Codex has no extra system prompt for exec: the topic's rules go before the first message
		args = append(append([]string{"exec"}, flags...), topicPrompt+"\n\n"+prompt)
	}
	sc, stderr, err := t.start(codexBinary(), args, cwd)
	if err != nil {
		return TurnResult{Error: err.Error()}
	}
	result := TurnResult{}
	var messages []string
	done := false
	threadID := ""
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
			threadID = e.ThreadID
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
	t.finish()
	if used, max := codexContext(firstNonEmpty(threadID, session)); max > 0 && ev.Context != nil {
		ev.Context(used, max)
	}
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

// How full a Codex session's context is: Codex writes it into the session file (the last request's tokens and the
// model's window)
func codexContext(thread string) (int, int) {
	if thread == "" {
		return 0, 0
	}
	home, _ := os.UserHomeDir()
	files, _ := filepath.Glob(filepath.Join(home, ".codex", "sessions", "*", "*", "*", "*"+thread+".jsonl"))
	if len(files) == 0 {
		return 0, 0
	}
	data, err := os.ReadFile(files[0])
	if err != nil {
		return 0, 0
	}
	used, max := 0, 0
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.Contains(line, `"token_count"`) {
			continue
		}
		var e struct {
			Payload struct {
				Info *struct {
					Last struct {
						Total int `json:"total_tokens"`
					} `json:"last_token_usage"`
					Window int `json:"model_context_window"`
				} `json:"info"`
			} `json:"payload"`
		}
		if json.Unmarshal([]byte(line), &e) == nil && e.Payload.Info != nil && e.Payload.Info.Window > 0 {
			used, max = e.Payload.Info.Last.Total, e.Payload.Info.Window
		}
	}
	return used, max
}
