package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// The engines' own limits, as they report them: Claude Code in its stream (rate_limit_event, the 5-hour and the weekly
// window), Codex in its session files (rate_limits, its windows in minutes). Kept in ~/.agentgram/limits.json, fresh
// after each answer; Agentgram shows them, and from 80% the bot warns the owner once per window.

type LimitWindow struct {
	Name     string  `json:"name"`      // "5h", "week", "month", or "Nmin"
	Percent  float64 `json:"percent"`   // used, 0..100
	ResetsAt int64   `json:"resets_at"` // unix seconds, 0 when unknown
}

type EngineLimits struct {
	Windows []LimitWindow `json:"windows"`
	Plan    string        `json:"plan,omitempty"`
	Time    int64         `json:"time"`
}

type limitsFile struct {
	Engines map[string]EngineLimits `json:"engines"`
	Warned  map[string]int64        `json:"warned"` // engine/window → the reset it was warned about
}

var limitsMu sync.Mutex

func limitsPath() string { return filepath.Join(dataDir(), "limits.json") }

func loadLimits() limitsFile {
	f := limitsFile{Engines: map[string]EngineLimits{}, Warned: map[string]int64{}}
	if data, err := os.ReadFile(limitsPath()); err == nil {
		_ = json.Unmarshal(data, &f)
	}
	if f.Engines == nil {
		f.Engines = map[string]EngineLimits{}
	}
	if f.Warned == nil {
		f.Warned = map[string]int64{}
	}
	return f
}

func allLimits() map[string]EngineLimits {
	limitsMu.Lock()
	defer limitsMu.Unlock()
	return loadLimits().Engines
}

// For Agentgram: what the engines last told, and Codex's from its files when it has not run through the helper yet
func knownLimits() map[string]EngineLimits {
	m := allLimits()
	if _, ok := m["codex"]; !ok && codexInstalled() {
		if l, ok := codexLimits(); ok {
			m["codex"] = l
		}
	}
	return m
}

// Saves an engine's fresh limits and returns the windows that just reached 80% (each once until it resets)
func saveLimits(engine string, l EngineLimits) []LimitWindow {
	limitsMu.Lock()
	defer limitsMu.Unlock()
	f := loadLimits()
	l.Time = time.Now().Unix()
	f.Engines[engine] = l
	var warn []LimitWindow
	for _, w := range l.Windows {
		key := engine + "/" + w.Name
		if w.Percent >= 80 && f.Warned[key] != w.ResetsAt {
			f.Warned[key] = w.ResetsAt
			warn = append(warn, w)
		}
	}
	data, _ := json.MarshalIndent(f, "", "  ")
	_ = writeFileAtomic(limitsPath(), data, 0o600)
	return warn
}

// Claude Code's rate_limit_event: rate_limit_info.unifiedWindows.{five_hour, seven_day}.{utilization 0..1, resetsAt}
func claudeLimits(raw []byte) (EngineLimits, bool) {
	var e struct {
		Info struct {
			Windows map[string]struct {
				Utilization float64 `json:"utilization"`
				ResetsAt    int64   `json:"resetsAt"`
			} `json:"unifiedWindows"`
		} `json:"rate_limit_info"`
	}
	if json.Unmarshal(raw, &e) != nil || len(e.Info.Windows) == 0 {
		return EngineLimits{}, false
	}
	var l EngineLimits
	for _, k := range []string{"five_hour", "seven_day"} {
		if w, ok := e.Info.Windows[k]; ok {
			name := map[string]string{"five_hour": "5h", "seven_day": "week"}[k]
			pct := w.Utilization
			if pct <= 1.5 {
				pct *= 100
			}
			l.Windows = append(l.Windows, LimitWindow{Name: name, Percent: pct, ResetsAt: w.ResetsAt})
		}
	}
	return l, len(l.Windows) > 0
}

// Codex writes rate_limits into its session file; the newest one tells the current state
func codexLimits() (EngineLimits, bool) {
	home, _ := os.UserHomeDir()
	var files []string
	_ = filepath.Walk(filepath.Join(home, ".codex", "sessions"), func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && strings.HasSuffix(p, ".jsonl") {
			files = append(files, p)
		}
		return nil
	})
	sort.Slice(files, func(i, j int) bool { return modTime(files[i]).After(modTime(files[j])) })
	for _, p := range files[:min(len(files), 3)] {
		if l, ok := lastCodexLimits(p); ok {
			return l, true
		}
	}
	return EngineLimits{}, false
}

func modTime(p string) time.Time {
	if st, err := os.Stat(p); err == nil {
		return st.ModTime()
	}
	return time.Time{}
}

func lastCodexLimits(path string) (EngineLimits, bool) {
	f, err := os.Open(path)
	if err != nil {
		return EngineLimits{}, false
	}
	defer f.Close()
	type window struct {
		UsedPercent   float64 `json:"used_percent"`
		WindowMinutes int     `json:"window_minutes"`
		ResetsAt      int64   `json:"resets_at"`
	}
	var last *struct {
		Primary   *window `json:"primary"`
		Secondary *window `json:"secondary"`
		PlanType  string  `json:"plan_type"`
	}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 32*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if !strings.Contains(string(line), `"rate_limits":{`) {
			continue
		}
		raw := findKey(line, "rate_limits")
		if raw == nil {
			continue
		}
		var rl struct {
			Primary   *window `json:"primary"`
			Secondary *window `json:"secondary"`
			PlanType  string  `json:"plan_type"`
		}
		if json.Unmarshal(raw, &rl) == nil && (rl.Primary != nil || rl.Secondary != nil) {
			last = &rl
		}
	}
	if last == nil {
		return EngineLimits{}, false
	}
	l := EngineLimits{Plan: last.PlanType}
	for _, w := range []*window{last.Primary, last.Secondary} {
		if w != nil {
			l.Windows = append(l.Windows, LimitWindow{Name: windowName(w.WindowMinutes), Percent: w.UsedPercent, ResetsAt: w.ResetsAt})
		}
	}
	return l, true
}

// The value of the first "key" anywhere in a JSON document
func findKey(doc []byte, key string) json.RawMessage {
	var v any
	if json.Unmarshal(doc, &v) != nil {
		return nil
	}
	var walk func(x any) any
	walk = func(x any) any {
		switch t := x.(type) {
		case map[string]any:
			if r, ok := t[key]; ok && r != nil {
				return r
			}
			for _, c := range t {
				if r := walk(c); r != nil {
					return r
				}
			}
		case []any:
			for _, c := range t {
				if r := walk(c); r != nil {
					return r
				}
			}
		}
		return nil
	}
	found := walk(v)
	if found == nil {
		return nil
	}
	data, _ := json.Marshal(found)
	return data
}

func windowName(minutes int) string {
	switch {
	case minutes == 300:
		return "5h"
	case minutes >= 10000 && minutes <= 10200:
		return "week"
	case minutes >= 40000:
		return "month"
	}
	return fmt.Sprintf("%dmin", minutes)
}

// «5-часовое», «недельное» window, as the bot says it
func windowWord(name string) string {
	switch name {
	case "5h":
		return "5-часовое"
	case "week":
		return "недельное"
	case "month":
		return "месячное"
	}
	return name
}

func resetText(at int64) string {
	if at == 0 {
		return ""
	}
	t := time.Unix(at, 0)
	now := time.Now()
	if t.YearDay() == now.YearDay() && t.Year() == now.Year() {
		return "сброс в " + t.Format("15:04")
	}
	months := []string{"января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"}
	return fmt.Sprintf("сброс %d %s", t.Day(), months[t.Month()-1])
}

// the same in English: «5-hour», «weekly»
func windowWordEn(name string) string {
	switch name {
	case "5h":
		return "5-hour"
	case "week":
		return "weekly"
	case "month":
		return "monthly"
	}
	return name
}

func resetTextEn(at int64) string {
	if at == 0 {
		return ""
	}
	t := time.Unix(at, 0)
	now := time.Now()
	if t.YearDay() == now.YearDay() && t.Year() == now.Year() {
		return "resets at " + t.Format("15:04")
	}
	return "resets " + t.Format("Jan 2")
}
