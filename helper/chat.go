package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// «Только ответы»: an engine with no tools at all. The agent answers through a language model (Qwen on OpenRouter by
// default) and can touch nothing on the computer: no files, no commands. For a demo agent, such as the one Apple's
// review talks to. Each topic keeps its own conversation in ~/.agentgram/chat/<session>.json.

const chatDefaultModel = "qwen/qwen3.8-flash"

const chatSystemPrompt = "Ты агент в Telepath, Telegram-клиенте для ИИ-агентов. Это демо: у тебя нет доступа к " +
	"компьютеру, файлам и командам, ты только отвечаешь. Отвечай коротко и по делу, на языке собеседника. " + topicPrompt

type ChatTurn struct {
	mu     sync.Mutex
	cancel chan struct{}
	Model  string
	Key    string
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

func chatPath(session string) string {
	return filepath.Join(dataDir(), "chat", session+".json")
}

func (t *ChatTurn) Stop() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.cancel != nil {
		close(t.cancel)
		t.cancel = nil
	}
}

func (t *ChatTurn) Run(cwd, session, prompt string, ev TurnEvents) TurnResult {
	if t.Key == "" {
		return TurnResult{Error: "нет ключа OpenRouter для «Только ответы»"}
	}
	if session == "" {
		b := make([]byte, 8)
		_, _ = rand.Read(b)
		session = hex.EncodeToString(b)
	}
	if ev.Session != nil {
		ev.Session(session)
	}
	var history []chatMessage
	if data, err := os.ReadFile(chatPath(session)); err == nil {
		_ = json.Unmarshal(data, &history)
	}
	history = append(history, chatMessage{Role: "user", Content: prompt})
	// the last 40 messages are enough for a demo, and keep the request small
	if len(history) > 40 {
		history = history[len(history)-40:]
	}
	if ev.Step != nil {
		ev.Step("Думаю")
	}
	cancel := make(chan struct{})
	t.mu.Lock()
	t.cancel = cancel
	t.mu.Unlock()
	type result struct {
		text string
		err  error
	}
	done := make(chan result, 1)
	go func() {
		text, err := chatComplete(t.Key, firstNonEmpty(t.Model, chatDefaultModel), append([]chatMessage{{Role: "system", Content: chatSystemPrompt}}, history...))
		done <- result{text, err}
	}()
	select {
	case <-cancel:
		return TurnResult{Error: "остановлено"}
	case r := <-done:
		if r.err != nil {
			return TurnResult{Error: r.err.Error()}
		}
		history = append(history, chatMessage{Role: "assistant", Content: r.text})
		_ = os.MkdirAll(filepath.Dir(chatPath(session)), 0o700)
		data, _ := json.Marshal(history)
		_ = writeFileAtomic(chatPath(session), data, 0o600)
		return TurnResult{Text: r.text}
	}
}

func chatComplete(key, model string, messages []chatMessage) (string, error) {
	body, _ := json.Marshal(map[string]any{"model": model, "messages": messages})
	req, _ := http.NewRequest("POST", "https://openrouter.ai/api/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 120 * time.Second}).Do(req)
	if err != nil {
		return "", fmt.Errorf("модель не ответила: %w", err)
	}
	defer resp.Body.Close()
	var res struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return "", fmt.Errorf("модель ответила %d", resp.StatusCode)
	}
	if res.Error != nil {
		return "", errors.New(res.Error.Message)
	}
	if len(res.Choices) == 0 || strings.TrimSpace(res.Choices[0].Message.Content) == "" {
		return "", errors.New("пустой ответ модели")
	}
	return strings.TrimSpace(res.Choices[0].Message.Content), nil
}
