package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// What the helper keeps on the computer, in ~/.agentgram: the bot it works as, its owner, and for each topic
// of the bot's chat the project folder and the engine's session. Nothing of it leaves the computer.

type Config struct {
	BotToken       string            `json:"bot_token"`
	OwnerID        int64             `json:"owner_id"`
	Engine         string            `json:"engine"`       // "claude" or "codex"
	ProjectsDir    string            `json:"projects_dir"` // where new projects are made and folders are listed from
	BotName        string            `json:"bot_name"`
	PhoneSecret    string            `json:"phone_secret"`    // from the phone that connected this computer, for its later requests
	AutostartAsked bool              `json:"autostart_asked"` // start at login was turned on once, at the first start
	WelcomeShown   bool              `json:"welcome_shown"`   // the first start's greeting was shown
	Statuses       string            `json:"statuses"`        // "off" (default): «typing…» only; "everywhere" (or the old "lan"): the steps streamed as drafts
	Voice          string            `json:"voice"`           // "off" (default), "whisper" (on this computer) or "groq"
	VoiceModel     string            `json:"voice_model"`     // Whisper's model: "light" or "accurate"
	GroqKey        string            `json:"groq_key"`        // the owner's Groq key, kept here only
	GroqModel      string            `json:"groq_model"`
	Lang           string            `json:"-"`                  // the agent's language, from its AgentConfig
	ChatKey        string            `json:"chat_key,omitempty"` // OpenRouter key of «Только ответы», kept here only
	Models         map[string]string `json:"models,omitempty"`   // the model of each engine; empty: the engine's own default
	Allowed        []Person          `json:"allowed,omitempty"`  // people besides the owner who may use the agent
	// Every bot this computer works as, each an agent with its own engine, model and people. The fields above
	// (token, name, owner, engine, models, allowed) are one agent's view: Agents[0] when saved, or the one asked about
	Agents []AgentConfig `json:"agents,omitempty"`
}

type AgentConfig struct {
	BotToken string            `json:"bot_token"`
	BotName  string            `json:"bot_name"`
	OwnerID  int64             `json:"owner_id"`
	Engine   string            `json:"engine"`
	Models   map[string]string `json:"models,omitempty"`
	Allowed  []Person          `json:"allowed,omitempty"`
	// the agent's own projects folder; empty: the computer's one
	ProjectsDir string `json:"projects_dir,omitempty"`
	// the language the bot speaks, «ru» or «en»; empty: the owner's Telegram language
	Lang string `json:"lang,omitempty"`
}

// The config as one agent sees it: its bot, owner, engine, models and people on top; false when there is no such bot
func (c Config) agent(bot string) (Config, bool) {
	for _, a := range c.Agents {
		if bot == "" || strings.EqualFold(a.BotName, bot) {
			c.BotToken, c.BotName, c.OwnerID, c.Engine, c.Models, c.Allowed, c.Lang = a.BotToken, a.BotName, a.OwnerID, firstNonEmpty(a.Engine, "claude"), a.Models, a.Allowed, a.Lang
			if a.ProjectsDir != "" {
				c.ProjectsDir = a.ProjectsDir
			}
			return c, true
		}
	}
	return c, false
}

// Writes one agent's view back into the list (the bot named in it), or adds it as a new agent
func (c *Config) putAgent(view Config) {
	a := AgentConfig{BotToken: view.BotToken, BotName: view.BotName, OwnerID: view.OwnerID, Engine: view.Engine, Models: view.Models, Allowed: view.Allowed}
	for i := range c.Agents {
		if strings.EqualFold(c.Agents[i].BotName, view.BotName) {
			a.ProjectsDir, a.Lang = c.Agents[i].ProjectsDir, c.Agents[i].Lang
			c.Agents[i] = a
			return
		}
	}
	c.Agents = append(c.Agents, a)
}

func (c *Config) removeAgent(bot string) {
	kept := c.Agents[:0:0]
	for _, a := range c.Agents {
		if !strings.EqualFold(a.BotName, bot) {
			kept = append(kept, a)
		}
	}
	c.Agents = kept
}

// Someone the owner let use the agent: they can do on this computer everything the owner can
type Person struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Added int64  `json:"added"`
}

type TopicState struct {
	Cwd     string `json:"cwd"`
	Session string `json:"session,omitempty"`
	Engine  string `json:"engine,omitempty"` // whose session it is: "claude" (also when empty) or "codex"
}

type State struct {
	mu     sync.Mutex
	path   string
	Offset int64                  `json:"offset"`
	Topics map[string]*TopicState `json:"topics"`
	// each topic's pinned messages, oldest first: Telegram tells the bot about a pin by a service message, and
	// Telepath sends «/unpin» when the owner unpins
	Pins map[string][]Pin `json:"pins,omitempty"`
	// the pins the topic's session was last told, so it hears about them again only when they change
	PinsSent map[string]string `json:"pins_sent,omitempty"`
}

type Pin struct {
	ID   int64  `json:"id"`
	Text string `json:"text"`
	Date int64  `json:"date"`
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
	// a config of one bot, from before agents: that bot is the first agent
	if len(c.Agents) == 0 && c.BotToken != "" {
		c.Agents = []AgentConfig{{BotToken: c.BotToken, BotName: c.BotName, OwnerID: c.OwnerID, Engine: c.Engine, Models: c.Models, Allowed: c.Allowed}}
	}
	if first, ok := c.agent(""); ok {
		dir := c.ProjectsDir
		c = first
		c.ProjectsDir = dir
	} else {
		c.BotToken, c.BotName, c.OwnerID, c.Models, c.Allowed = "", "", 0, nil, nil
	}
	if c.Engine == "" {
		c.Engine = "claude"
	}
	if c.ProjectsDir == "" {
		c.ProjectsDir = defaultProjectsDir()
	}
	return c, err
}

func saveConfig(c Config) error {
	if err := os.MkdirAll(dataDir(), 0o700); err != nil {
		return err
	}
	// the top fields always mirror the first agent, for older readers (the computer's folder stays its own)
	if first, ok := c.agent(""); ok {
		dir := c.ProjectsDir
		c = first
		c.ProjectsDir = dir
	} else {
		c.BotToken, c.BotName, c.OwnerID, c.Models, c.Allowed = "", "", 0, nil, nil
	}
	data, _ := json.MarshalIndent(c, "", "  ")
	return writeFileAtomic(filepath.Join(dataDir(), "helper.json"), data, 0o600)
}

// Each agent keeps its own topics and offset: state-<bot>.json; the first agent takes over the state.json of before
func loadState(bot string) *State {
	path := filepath.Join(dataDir(), "state-"+strings.ToLower(bot)+".json")
	if _, err := os.Stat(path); err != nil {
		if old := filepath.Join(dataDir(), "state.json"); fileExists(old) {
			if cfg, _ := loadConfig(); strings.EqualFold(cfg.BotName, bot) {
				_ = os.Rename(old, path)
			}
		}
	}
	s := &State{path: path, Topics: map[string]*TopicState{}}
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

func (s *State) setSession(key, session, engine string) {
	s.mu.Lock()
	if t, ok := s.Topics[key]; ok {
		t.Session, t.Engine = session, engine
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

// Where people usually keep projects; the first that exists, else ~/Projects (made when the first project is)
func defaultProjectsDir() string {
	home, _ := os.UserHomeDir()
	for _, d := range []string{"orca/projects", "Projects", "Developer", "Code", "projects", "dev"} {
		if st, err := os.Stat(filepath.Join(home, d)); err == nil && st.IsDir() {
			return filepath.Join(home, d)
		}
	}
	return filepath.Join(home, "Projects")
}

// An agent's own folder (empty: back to the computer's)
func (c *Config) setAgentFolder(bot, dir string) {
	for i := range c.Agents {
		if strings.EqualFold(c.Agents[i].BotName, bot) {
			c.Agents[i].ProjectsDir = dir
		}
	}
}

// An agent's model for an engine (empty: the engine's own)
func (c *Config) setAgentModel(bot, engine, model string) {
	for i := range c.Agents {
		if strings.EqualFold(c.Agents[i].BotName, bot) {
			if c.Agents[i].Models == nil {
				c.Agents[i].Models = map[string]string{}
			}
			c.Agents[i].Models[engine] = model
		}
	}
}

// most pins a topic keeps; the oldest goes first
const maxPins = 10

func (s *State) addPin(key string, p Pin) {
	s.mu.Lock()
	if s.Pins == nil {
		s.Pins = map[string][]Pin{}
	}
	pins := s.Pins[key][:0:0]
	for _, old := range s.Pins[key] {
		if old.ID != p.ID {
			pins = append(pins, old)
		}
	}
	pins = append(pins, p)
	if len(pins) > maxPins {
		pins = pins[len(pins)-maxPins:]
	}
	s.Pins[key] = pins
	s.mu.Unlock()
	s.save()
}

// removePin takes one pin off the topic, or all of them when id is 0
func (s *State) removePin(key string, id int64) {
	s.mu.Lock()
	var pins []Pin
	if id != 0 {
		for _, p := range s.Pins[key] {
			if p.ID != id {
				pins = append(pins, p)
			}
		}
	}
	if len(pins) == 0 {
		delete(s.Pins, key)
	} else {
		s.Pins[key] = pins
	}
	s.mu.Unlock()
	s.save()
}

// pinsNote is the block put before the owner's message when the topic's pins changed since its session last heard
// them: the list, or that there are none any more. Empty when nothing changed.
func (s *State) pinsNote(key string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	pins := s.Pins[key]
	var b strings.Builder
	for i, p := range pins {
		fmt.Fprintf(&b, "%d. (сообщение %d, %s) %s\n", i+1, p.ID, time.Unix(p.Date, 0).Format("02.01 15:04"), p.Text)
	}
	sig := fmt.Sprintf("%x", sha256.Sum256([]byte(b.String())))
	last, told := s.PinsSent[key]
	if last == sig || (!told && len(pins) == 0) {
		return ""
	}
	if s.PinsSent == nil {
		s.PinsSent = map[string]string{}
	}
	s.PinsSent[key] = sig
	go s.save()
	if len(pins) == 0 {
		return "[Закрепов в теме больше нет]\n\n"
	}
	return "[Закрепы темы, весь список]\n" + b.String() + "[конец закрепов]\n\n"
}
