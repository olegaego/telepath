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
