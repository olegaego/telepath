package main

import (
	"errors"
	"strings"
	"sync"
	"time"
)

// What each topic is doing, for Agentgram. Away from home the phone reads it from the bot itself: the live draft with
// the steps (streamed through one budget per chat, so it never hits Telegram's limits), a question, «Ошибка», the
// answer. On the same Wi-Fi the phone asks the helper directly (/status) and sees every step at once.

type StatusStep struct {
	Text string `json:"text"`
	Secs int    `json:"secs"`
}

type TopicStatus struct {
	Bot    string       `json:"bot"` // the agent's bot, of several on this computer
	Chat   int64        `json:"chat"`
	Thread int64        `json:"thread"`
	State  string       `json:"state"` // working, queued, waiting_you, error, idle
	Detail string       `json:"detail"`
	Since  int64        `json:"since"`
	Engine string       `json:"engine"`
	Queued int          `json:"queued"`
	Steps  []StatusStep `json:"steps,omitempty"`
	// how full the session's context is, in tokens
	Context *ContextUse `json:"context,omitempty"`
}

type ContextUse struct {
	Used int `json:"used"`
	Max  int `json:"max"`
}

type statusBoard struct {
	mu     sync.Mutex
	topics map[string]*TopicStatus
}

func newStatusBoard() *statusBoard {
	return &statusBoard{topics: map[string]*TopicStatus{}}
}

func (b *statusBoard) set(key string, update func(s *TopicStatus)) {
	b.mu.Lock()
	defer b.mu.Unlock()
	s := b.topics[key]
	if s == nil {
		s = &TopicStatus{}
		b.topics[key] = s
	}
	update(s)
}

func (b *statusBoard) list() []TopicStatus {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]TopicStatus, 0, len(b.topics))
	for _, s := range b.topics {
		c := *s
		c.Steps = append([]StatusStep(nil), s.Steps...)
		out = append(out, c)
	}
	return out
}

// One budget of drafts per chat (all topics of the bot share one private chat, and Telegram counts per chat): a draft
// at most every 1.5 s, and none while Telegram asked to wait
type draftBudget struct {
	mu    sync.Mutex
	next  map[int64]time.Time
	pause map[int64]time.Time
}

// Telegram takes about one draft a second per chat (measured: once a second never refused, twice a second soon
// «retry after 10 s»), so the chat's drafts go one per 1.5 s whatever the number of topics
const draftEvery = 1500 * time.Millisecond

// a turn shorter than this streams no draft: a quick answer comes alone
const draftAfter = 3 * time.Second

// a draft lives 30 s in Telegram: the same step is streamed again before that
const draftKeep = 25 * time.Second

func newDraftBudget() *draftBudget {
	return &draftBudget{next: map[int64]time.Time{}, pause: map[int64]time.Time{}}
}

func (b *draftBudget) take(chat int64) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := time.Now()
	if now.Before(b.pause[chat]) || now.Before(b.next[chat]) {
		return false
	}
	b.next[chat] = now.Add(draftEvery)
	return true
}

// Telegram said «retry after N s»: no drafts in this chat until then
func (b *draftBudget) obey(chat int64, err error) {
	var apiErr *APIError
	if errors.As(err, &apiErr) && apiErr.RetryAfter > 0 {
		b.mu.Lock()
		b.pause[chat] = time.Now().Add(time.Duration(apiErr.RetryAfter) * time.Second)
		b.mu.Unlock()
	}
}

// The draft's text: the last steps, done ones with ✓, the current one with …
func draftText(steps []string) string {
	lines := []string{}
	for i, s := range steps {
		if i == len(steps)-1 {
			lines = append(lines, "… "+s)
		} else {
			lines = append(lines, "✓ "+s)
		}
	}
	if len(lines) > 8 {
		lines = lines[len(lines)-8:]
	}
	return strings.Join(lines, "\n")
}

// Turns started today, for the counters on the agent's screen in Agentgram
var todayTurns = struct {
	sync.Mutex
	day   string
	count int
}{}

func countTurn(t time.Time) {
	todayTurns.Lock()
	defer todayTurns.Unlock()
	if day := t.Format("2006-01-02"); day != todayTurns.day {
		todayTurns.day, todayTurns.count = day, 0
	}
	todayTurns.count++
}

func turnsToday() int {
	todayTurns.Lock()
	defer todayTurns.Unlock()
	if todayTurns.day != time.Now().Format("2006-01-02") {
		return 0
	}
	return todayTurns.count
}
