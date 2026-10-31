package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// What the helper keeps on the computer, in ~/.agentgram: the bot it works as, its owner, and for each topic
// of the bot's chat the project folder and the engine's session. Nothing of it leaves the computer.

type Config struct {
	BotToken    string `json:"bot_token"`
	OwnerID     int64  `json:"owner_id"`
	Engine      string `json:"engine"`       // "claude" or "codex"
	ProjectsDir string `json:"projects_dir"` // where new projects are made and folders are listed from
}

type TopicState struct {
	Cwd     string `json:"cwd"`
	Session string `json:"session,omitempty"`
}

type State struct {
	mu     sync.Mutex
	path   string
	Offset int64                  `json:"offset"`
	Topics map[string]*TopicState `json:"topics"`
}

func dataDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".agentgram")
}

func loadConfig() (Config, error) {
	var c Config
	data, err := os.ReadFile(filepath.Join(dataDir(), "helper.json"))
	if err != nil {
		return c, err
	}
	err = json.Unmarshal(data, &c)
	if c.Engine == "" {
		c.Engine = "claude"
	}
	if c.ProjectsDir == "" {
		home, _ := os.UserHomeDir()
		c.ProjectsDir = filepath.Join(home, "Projects")
	}
	return c, err
}

func saveConfig(c Config) error {
	if err := os.MkdirAll(dataDir(), 0o700); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(c, "", "  ")
	return writeFileAtomic(filepath.Join(dataDir(), "helper.json"), data, 0o600)
}

func loadState() *State {
	s := &State{path: filepath.Join(dataDir(), "state.json"), Topics: map[string]*TopicState{}}
	if data, err := os.ReadFile(s.path); err == nil {
		_ = json.Unmarshal(data, s)
	}
	if s.Topics == nil {
		s.Topics = map[string]*TopicState{}
	}
	return s
}

func (s *State) save() {
	s.mu.Lock()
	data, _ := json.MarshalIndent(s, "", "  ")
	s.mu.Unlock()
	_ = writeFileAtomic(s.path, data, 0o600)
}

func (s *State) topic(key string) (TopicState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.Topics[key]
	if !ok {
		return TopicState{}, false
	}
	return *t, true
}

func (s *State) setTopic(key string, t TopicState) {
	s.mu.Lock()
	s.Topics[key] = &t
	s.mu.Unlock()
	s.save()
}

func (s *State) setSession(key, session string) {
	s.mu.Lock()
	if t, ok := s.Topics[key]; ok {
		t.Session = session
	}
	s.mu.Unlock()
	s.save()
}

func (s *State) setOffset(offset int64) {
	s.mu.Lock()
	s.Offset = offset
	s.mu.Unlock()
	s.save()
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
