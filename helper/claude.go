package main

import (
	"encoding/json"
	"os/exec"
	"path/filepath"
	"strings"
)

// One turn of Claude Code in a project folder: the official `claude` CLI, its session resumed, its stream read
// line by line. The helper only starts it and reads what it prints; the login stays Claude Code's own.

type TurnEvents struct {
	Step    func(text string)   // what it does now, for the draft in the topic
	Session func(id string)     // the session id, to resume the next turn
	Limits  func(EngineLimits)  // the engine's limits, when it tells them
	Context func(used, max int) // how full the session's context is, in tokens
}

type TurnResult struct {
	Text  string
	Error string
	// the session was compacted during the turn (by «/compact» or by itself when full): tokens before and after,
	// After 0 when the engine does not tell
	Compacted *Compaction
}

// the step shown while the session is compacted
const compactingStep = "Сжимаю сессию"

// the message that compacts a topic's session, for every engine
const compactCommand = "/compact"

type Compaction struct {
	Before, After int
}

// The instruction added to every turn: the topic has no question dialogs, choices come as buttons.
const topicPrompt = "Ты отвечаешь в теме Telegram, диалогов с вопросами тут нет. Отвечай на языке собеседника. Когда даёшь выбор, задай один вопрос " +
	"и закончи ответ блоком ```варианты```: по варианту в строке, коротко (до 60 знаков), без нумерации. " +
	"Из блока получатся кнопки, нажатый вариант придёт следующим сообщением. " +
	"Экран, макет или картинку показывай фотографией: сделай HTML-файл (экран телефона 390×844, без внешних запросов, " +
	"кроме шрифтов) или PNG/JPG и добавь в ответ строку [[фото: путь]], по строке на файл, до 10; для HTML другого " +
	"размера [[фото: путь 1280x800]]. HTML снимется в картинку, несколько придут альбомом перед текстом ответа."

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

// Reads one turn of Claude Code's stream-json from `next` until its result; false when the lines ended first
// window carries the session's context window from turn to turn: a living process says its model (and so a
// 1M window) only once, at its start
func readClaudeTurn(next func() ([]byte, bool), ev TurnEvents, window *int) (TurnResult, bool) {
	result := TurnResult{}
	contextUsed, contextMax := 0, 200000
	spoke := false // Claude said something after the last compaction
	if *window > 0 {
		contextMax = *window
	}
	defer func() { *window = contextMax }()
	for {
		line, ok := next()
		if !ok {
			return result, false
		}
		var e struct {
			Type      string  `json:"type"`
			SessionID string  `json:"session_id"`
			IsError   bool    `json:"is_error"`
			Result    string  `json:"result"`
			Subtype   string  `json:"subtype"`
			Model     string  `json:"model"`
			Status    *string `json:"status"`
			Compact   *struct {
				Pre  int `json:"pre_tokens"`
				Post int `json:"post_tokens"`
			} `json:"compact_metadata"`
			// the result's per-model usage carries the context window
			ModelUsage map[string]struct {
				ContextWindow int `json:"contextWindow"`
			} `json:"modelUsage"`
			Message struct {
				Usage *struct {
					InputTokens   int `json:"input_tokens"`
					CacheRead     int `json:"cache_read_input_tokens"`
					CacheCreation int `json:"cache_creation_input_tokens"`
				} `json:"usage"`
				Content []struct {
					Type  string         `json:"type"`
					Name  string         `json:"name"`
					Input map[string]any `json:"input"`
				} `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(line, &e) != nil {
			continue
		}
		if e.SessionID != "" && ev.Session != nil {
			ev.Session(e.SessionID)
		}
		switch e.Type {
		case "system":
			if e.Subtype == "init" && e.Model != "" {
				seenModel("claude", e.Model)
				contextMax = 200000
				if strings.HasSuffix(e.Model, "[1m]") {
					contextMax = 1000000
				}
			}
			if e.Subtype == "status" && e.Status != nil && *e.Status == "compacting" && ev.Step != nil {
				ev.Step(compactingStep)
			}
			if e.Subtype == "compact_boundary" && e.Compact != nil {
				result.Compacted = &Compaction{Before: e.Compact.Pre, After: e.Compact.Post}
				spoke = false
				if e.Compact.Post > 0 {
					contextUsed = e.Compact.Post
					if ev.Context != nil {
						ev.Context(contextUsed, contextMax)
					}
				}
			}
		case "rate_limit_event":
			if l, ok := claudeLimits(line); ok && ev.Limits != nil {
				ev.Limits(l)
			}
		case "assistant":
			spoke = true
			if u := e.Message.Usage; u != nil && ev.Context != nil {
				contextUsed = u.InputTokens + u.CacheRead + u.CacheCreation
				ev.Context(contextUsed, contextMax)
			}
			for _, b := range e.Message.Content {
				if b.Type == "tool_use" && ev.Step != nil {
					ev.Step(describeTool(b.Name, b.Input))
				}
			}
		case "result":
			for _, u := range e.ModelUsage {
				if u.ContextWindow > 0 && contextUsed > 0 && ev.Context != nil {
					contextMax = u.ContextWindow
					ev.Context(contextUsed, contextMax)
					break
				}
			}
			if e.IsError {
				result.Error = firstNonEmpty(e.Result, e.Subtype, "ошибка Claude Code")
			} else if result.Compacted == nil || spoke {
				// after «/compact» alone the result is the command's own output, not an answer
				result.Text = e.Result
			}
			return result, true
		}
	}
}
