package main

import (
	"bufio"
	"encoding/json"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// One turn of Claude Code in a project folder: the official `claude` CLI, its session resumed, its stream read
// line by line. The helper only starts it and reads what it prints; the login stays Claude Code's own.

type TurnEvents struct {
	Step    func(text string) // what it does now, for the draft in the topic
	Session func(id string)   // the session id, to resume the next turn
}

type TurnResult struct {
	Text  string
	Error string
}

// The instruction added to every turn: the topic has no question dialogs, choices come as buttons.
const topicPrompt = "Ты отвечаешь в теме Telegram, диалогов с вопросами тут нет. Когда даёшь выбор, задай один вопрос " +
	"и закончи ответ блоком ```варианты```: по варианту в строке, коротко (до 60 знаков), без нумерации. " +
	"Из блока получатся кнопки, нажатый вариант придёт следующим сообщением."

var toolWords = map[string]string{
	"Read": "Читаю", "Edit": "Правлю", "Write": "Пишу", "MultiEdit": "Правлю", "NotebookEdit": "Правлю",
	"Grep": "Ищу в коде", "Glob": "Ищу файлы", "WebFetch": "Читаю страницу", "WebSearch": "Ищу в интернете",
	"Task": "Запускаю помощника", "Agent": "Запускаю помощника", "TodoWrite": "Составляю план",
}

func describeTool(name string, input map[string]any) string {
	str := func(k string) string {
		v, _ := input[k].(string)
		return v
	}
	if name == "Bash" {
		d := str("description")
		if d == "" {
			d = str("command")
		}
		return trim("Запускаю: "+d, 80)
	}
	target := filepath.Base(firstNonEmpty(str("file_path"), str("path"), str("notebook_path")))
	if target == "." || target == "/" {
		target = ""
	}
	if target == "" {
		target = firstNonEmpty(str("pattern"), str("query"), str("url"))
	}
	word := toolWords[name]
	if word == "" {
		word = "Работаю"
	}
	return trim(strings.TrimSpace(word+" "+target), 120)
}

type ClaudeTurn struct {
	mu  sync.Mutex
	cmd *exec.Cmd
}

func (t *ClaudeTurn) Stop() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.cmd != nil && t.cmd.Process != nil {
		_ = t.cmd.Process.Kill()
	}
}

func (t *ClaudeTurn) Run(bin, cwd, session, prompt string, ev TurnEvents) TurnResult {
	args := []string{"-p", "--output-format", "stream-json", "--verbose",
		"--permission-mode", "bypassPermissions", "--append-system-prompt", topicPrompt}
	if session != "" {
		args = append(args, "--resume", session)
	}
	args = append(args, prompt)
	cmd := exec.Command(bin, args...)
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
	gotResult := false
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		var e struct {
			Type      string `json:"type"`
			SessionID string `json:"session_id"`
			IsError   bool   `json:"is_error"`
			Result    string `json:"result"`
			Subtype   string `json:"subtype"`
			Message   struct {
				Content []struct {
					Type  string         `json:"type"`
					Name  string         `json:"name"`
					Input map[string]any `json:"input"`
				} `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(sc.Bytes(), &e) != nil {
			continue
		}
		if e.SessionID != "" && ev.Session != nil {
			ev.Session(e.SessionID)
		}
		switch e.Type {
		case "assistant":
			for _, b := range e.Message.Content {
				if b.Type == "tool_use" && ev.Step != nil {
					ev.Step(describeTool(b.Name, b.Input))
				}
			}
		case "result":
			gotResult = true
			if e.IsError {
				result.Error = firstNonEmpty(e.Result, e.Subtype, "ошибка Claude Code")
			} else {
				result.Text = e.Result
			}
		}
	}
	_ = cmd.Wait()
	t.mu.Lock()
	t.cmd = nil
	t.mu.Unlock()
	if !gotResult && result.Error == "" {
		result.Error = firstNonEmpty(strings.TrimSpace(stderr.String()), "Claude Code остановился")
	}
	return result
}

// Where `claude` is: on PATH, or where its installer puts it
func claudeBinary() string {
	if p, err := exec.LookPath("claude"); err == nil {
		return p
	}
	home := homeDir()
	for _, p := range []string{filepath.Join(home, ".local", "bin", "claude"), filepath.Join(home, ".claude", "local", "claude")} {
		if fileExists(p) {
			return p
		}
	}
	return "claude"
}

type limitedWriter struct {
	b   *strings.Builder
	max int
}

func (w *limitedWriter) Write(p []byte) (int, error) {
	if w.b.Len() < w.max {
		w.b.Write(p)
	}
	return len(p), nil
}
