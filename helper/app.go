package main

import (
	"fmt"
	"log"
	"strings"
	"sync"
	"time"
)

// The helper's work, the same with the menu-bar icon or without it: waits for the phone, then works as each of its
// bots (agents) until they are disconnected; agents added or removed from the phone start and stop on the fly
type App struct {
	network *Network
	ui      UI
	mu      sync.Mutex
	helpers map[string]*running // by the bot's name, lower case
}

type running struct {
	helper *Helper
	stop   chan struct{}
}

// What the icon's menu shows; nothing when the helper runs without it
type UI interface {
	Waiting(code string)
	Working(bots []string, engine string)
	Paired(bot, engine string)
	EngineChanged(engine string)
	StatusesChanged(mode string)
	VoiceChanged(cfg Config)
}

func (a *App) all() []*Helper {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := []*Helper{}
	for _, r := range a.helpers {
		out = append(out, r.helper)
	}
	return out
}

// The agent of that bot; an empty name is the first agent
func (a *App) helperOf(bot string) *Helper {
	if bot == "" {
		cfg, _ := loadConfig()
		bot = cfg.BotName
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if r := a.helpers[strings.ToLower(bot)]; r != nil {
		return r.helper
	}
	return nil
}

func (a *App) run(cfg Config) {
	for {
		if len(cfg.Agents) == 0 {
			fmt.Println()
			fmt.Println("Жду Telepath в этой сети.")
			fmt.Println("В Telepath: Настройки → Telepath → Добавить агента → «" + computerName() + "».")
			fmt.Println("Код на телефоне должен быть таким:  " + a.network.Code())
			fmt.Println()
			if a.ui != nil {
				a.ui.Waiting(a.network.Code())
			}
			cfg = <-a.network.Paired
			log.Println("подключён")
			if a.ui != nil {
				a.ui.Paired(cfg.BotName, cfg.Engine)
			}
		}
		a.sync()
		// until every agent is gone: each change of the list starts or stops agents
		for {
			<-a.network.AgentsChanged
			a.sync()
			if cfg, _ = loadConfig(); len(cfg.Agents) == 0 {
				break
			}
		}
		log.Println("отключён")
	}
}

// Starts the agents of the config not working yet, stops the ones gone from it, gives the rest the fresh config
func (a *App) sync() {
	cfg, _ := loadConfig()
	want := map[string]Config{}
	for _, ag := range cfg.Agents {
		if view, ok := cfg.agent(ag.BotName); ok {
			want[strings.ToLower(ag.BotName)] = view
		}
	}
	a.mu.Lock()
	for name, r := range a.helpers {
		if _, ok := want[name]; !ok {
			close(r.stop)
			delete(a.helpers, name)
			log.Printf("агент @%s отключён", name)
		}
	}
	for name, view := range want {
		if r := a.helpers[name]; r != nil {
			r.helper.mu.Lock()
			r.helper.cfg = view
			r.helper.mu.Unlock()
			continue
		}
		h := &Helper{cfg: view, bot: NewBot(view.BotToken), state: loadState(view.BotName), topics: map[string]*topicWork{}, pending: map[string]*pendingChoice{}}
		bot := view.BotName
		h.switchEngine = func(engine string) { a.setEngine(bot, engine) }
		h.board, h.drafts = newStatusBoard(), newDraftBudget()
		r := &running{helper: h, stop: make(chan struct{})}
		a.helpers[name] = r
		go func() {
			for {
				me, err := h.bot.GetMe()
				if err == nil {
					log.Printf("работаю как @%s, хозяин %d, движок %s", me.Username, view.OwnerID, view.Engine)
					break
				}
				log.Println("бот не отвечает: ", err)
				select {
				case <-r.stop:
					return
				case <-time.After(10 * time.Second):
				}
			}
			h.loop(r.stop)
		}()
	}
	bots := []string{}
	for _, ag := range cfg.Agents {
		bots = append(bots, ag.BotName)
	}
	a.mu.Unlock()
	if a.ui != nil && len(bots) > 0 {
		a.ui.Working(bots, cfg.Engine)
	}
}

// Topics and running turns of all the agents, for the menu
func (a *App) status() (topics, running int, ok bool) {
	helpers := a.all()
	for _, h := range helpers {
		st := h.status()
		topics += st["topics"].(int)
		running += st["running"].(int)
	}
	return topics, running, len(helpers) > 0
}

// An agent's own projects folder, from the menu: saved, and the agent lists projects from it at once
func (a *App) setAgentFolder(bot, dir string) {
	cfg, _ := loadConfig()
	cfg.setAgentFolder(bot, dir)
	_ = saveConfig(cfg)
	a.sync()
	if a.ui != nil {
		a.ui.EngineChanged("")
	}
}

// An agent's model, from the menu: its next turns run on it
func (a *App) setModel(bot, engine, model string) {
	cfg, _ := loadConfig()
	cfg.setAgentModel(bot, engine, model)
	_ = saveConfig(cfg)
	a.sync()
	if a.ui != nil {
		a.ui.EngineChanged("")
	}
}

// Another engine for an agent (from the phone, the menu or /engine in its chat): saved, and its next turns go to
// it (a turn going now finishes on the old one). An empty bot is the first agent
func (a *App) setEngine(bot, engine string) {
	cfg, _ := loadConfig()
	view, ok := cfg.agent(bot)
	if !ok {
		return
	}
	view.Engine = engine
	cfg.putAgent(view)
	_ = saveConfig(cfg)
	cfg, _ = loadConfig()
	a.network.reannounce(cfg)
	a.sync()
	if a.ui != nil {
		a.ui.EngineChanged(engine)
	}
}

// Settings changed (voice, a model, the people let in; from the phone or the menu): the agents take them at once
func (a *App) settingsChanged(cfg Config) {
	a.sync()
	if a.ui != nil {
		a.ui.VoiceChanged(cfg)
	}
}

// How statuses reach the phone, chosen in Agentgram or in the menu here
func (a *App) setStatuses(mode string) {
	if mode != "off" && mode != "lan" && mode != "everywhere" {
		return
	}
	cfg, _ := loadConfig()
	cfg.Statuses = mode
	_ = saveConfig(cfg)
	a.sync()
	if a.ui != nil {
		a.ui.StatusesChanged(mode)
	}
}
