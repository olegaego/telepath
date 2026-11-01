package main

import (
	_ "embed"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"fyne.io/systray"
)

// The helper lives as an icon in the Mac's menu bar or by the clock on Windows; no terminal. Its menu is the system
// one: lines, checkmarks, a submenu. Waiting: what to open on the phone and this computer's code. Working: the bot,
// its sessions, the engine and the projects folder, «Disconnect».

//go:embed icon/menubar.png
var menubarIcon []byte

//go:embed icon/tray.ico
var trayIcon []byte

type Tray struct {
	app           *App
	status        *systray.MenuItem
	line          *systray.MenuItem
	where         *systray.MenuItem
	code          *systray.MenuItem
	agentsTitle   *systray.MenuItem
	agents        []*agentMenu // slots: one per agent, the unused ones hidden
	statuses      *systray.MenuItem
	voice         *systray.MenuItem
	voiceOff      *systray.MenuItem
	voiceLight    *systray.MenuItem
	voiceAccurate *systray.MenuItem
	voiceGroq     *systray.MenuItem
	statusOff     *systray.MenuItem
	statusAll     *systray.MenuItem
	login         *systray.MenuItem
	update        *systray.MenuItem // «Обновить до …» once a newer helper is out
	checkUpdates  *systray.MenuItem
	bot           string
}

// One agent's line in the menu and its submenu: the chat, the engine, the model, the folder, «Отключить»
type agentMenu struct {
	item     *systray.MenuItem
	openChat *systray.MenuItem
	engine   *systray.MenuItem
	claude   *systray.MenuItem
	codex    *systray.MenuItem
	model    *systray.MenuItem
	models   []*systray.MenuItem
	folder   *systray.MenuItem
	remove   *systray.MenuItem
	bot      string
	engineID string
	modelIDs []string
}

const (
	maxMenuAgents = 8
	maxMenuModels = 8
)

func runTray(app *App, cfg Config) {
	t := &Tray{app: app}
	app.ui = t
	systray.Run(func() { t.ready(cfg) }, nil)
}

func (t *Tray) ready(cfg Config) {
	systray.SetTemplateIcon(menubarIcon, trayIcon)
	systray.SetTooltip("Telepath")

	t.status = systray.AddMenuItem("Telepath", "")
	t.status.Disable()
	t.line = systray.AddMenuItem("", "")
	t.line.Disable()
	t.where = systray.AddMenuItem("Настройки → Telepath → Агенты", "")
	t.where.Disable()
	t.code = systray.AddMenuItem("", "")
	t.code.Disable()
	systray.AddSeparator()
	t.agentsTitle = systray.AddMenuItem("Агенты", "")
	t.agentsTitle.Disable()
	for i := 0; i < maxMenuAgents; i++ {
		m := &agentMenu{item: systray.AddMenuItem("", "")}
		m.openChat = m.item.AddSubMenuItem("Открыть чат в Telegram", "")
		m.engine = m.item.AddSubMenuItem("Движок", "")
		m.claude = m.engine.AddSubMenuItemCheckbox("Claude Code", "", false)
		m.codex = m.engine.AddSubMenuItemCheckbox("Codex", "", false)
		if !codexInstalled() {
			m.codex.SetTitle("Codex (не установлен)")
			m.codex.Disable()
		}
		m.model = m.item.AddSubMenuItem("Модель", "")
		for j := 0; j < maxMenuModels; j++ {
			mm := m.model.AddSubMenuItemCheckbox("", "", false)
			mm.Hide()
			m.models = append(m.models, mm)
		}
		m.folder = m.item.AddSubMenuItem("", "")
		m.remove = m.item.AddSubMenuItem("Отключить…", "")
		m.item.Hide()
		t.agents = append(t.agents, m)
		go t.listen(m)
	}
	t.agentsTitle.Hide()
	systray.AddSeparator()
	// two choices; «lan», the old middle one, counts as «Подробные»
	t.statuses = systray.AddMenuItem("Статусы", "")
	t.statusOff = t.statuses.AddSubMenuItemCheckbox("Стандартные: «печатает…»", "", firstNonEmpty(cfg.Statuses, "off") == "off")
	t.statusAll = t.statuses.AddSubMenuItemCheckbox("Подробные: что делает, шаги, время", "", firstNonEmpty(cfg.Statuses, "off") != "off")
	t.voice = systray.AddMenuItem("Голосовые", "")
	t.voiceOff = t.voice.AddSubMenuItemCheckbox("Выключены", "", firstNonEmpty(cfg.Voice, "off") == "off")
	t.voiceLight = t.voice.AddSubMenuItemCheckbox("Whisper на этом Маке: лёгкая (148 МБ)", "", cfg.Voice == "whisper" && cfg.VoiceModel != "accurate")
	t.voiceAccurate = t.voice.AddSubMenuItemCheckbox("Whisper на этом Маке: точная (574 МБ)", "", cfg.Voice == "whisper" && cfg.VoiceModel == "accurate")
	t.voiceGroq = t.voice.AddSubMenuItemCheckbox("Groq (ключ вставляется в Telepath)", "", cfg.Voice == "groq")
	t.login = systray.AddMenuItemCheckbox("Запускать при входе", "", autostartEnabled())
	systray.AddSeparator()
	t.update = systray.AddMenuItem("", "")
	t.update.Hide()
	t.checkUpdates = systray.AddMenuItem("Проверить обновления (версия "+version+")", "")
	quit := systray.AddMenuItem("Выйти", "")

	// the first start: on by itself, as people expect from such an app; later starts keep it pointing at where the app is now
	if autostartEnabled() {
		_ = setAutostart(true)
	}
	if !cfg.AutostartAsked {
		cfg.AutostartAsked = true
		_ = saveConfig(cfg)
		if setAutostart(true) == nil {
			t.login.Check()
		}
	}

	go func() {
		for {
			select {
			case <-t.voiceOff.ClickedCh:
				t.setVoice("off", "")
			case <-t.voiceLight.ClickedCh:
				t.setVoice("whisper", "light")
			case <-t.voiceAccurate.ClickedCh:
				t.setVoice("whisper", "accurate")
			case <-t.voiceGroq.ClickedCh:
				t.setVoice("groq", "")
			case <-t.statusOff.ClickedCh:
				t.app.setStatuses("off")
			case <-t.statusAll.ClickedCh:
				t.app.setStatuses("everywhere")
			case <-t.login.ClickedCh:
				on := !t.login.Checked()
				if setAutostart(on) == nil {
					if on {
						t.login.Check()
					} else {
						t.login.Uncheck()
					}
				}
			case <-t.update.ClickedCh:
				if r := availableUpdate(); r != nil {
					t.update.SetTitle("Обновляю до " + r.Version + "…")
					t.update.Disable()
					if err := installUpdate(r); err != nil {
						log.Println("обновление:", err)
						alert("Не вышло обновить", err.Error())
						t.update.SetTitle("Обновить до " + r.Version)
						t.update.Enable()
					} else {
						t.app.network.Shutdown()
						systray.Quit()
						os.Exit(0)
					}
				}
			case <-t.checkUpdates.ClickedCh:
				if r, err := checkUpdate(); err != nil {
					alert("Обновления", "Не вышло проверить: "+err.Error())
				} else if r == nil {
					alert("Обновления", "У тебя последняя версия, "+version+".")
				} else {
					t.updateFound(r)
				}
			case <-quit.ClickedCh:
				t.app.network.Shutdown()
				systray.Quit()
				os.Exit(0)
			}
		}
	}()
	go t.refresh()
	go watchUpdates(t.updateFound)
	go t.app.run(cfg)
}

// What one agent's submenu does; the slot's bot changes as agents come and go
func (t *Tray) listen(m *agentMenu) {
	modelClicks := make(chan int)
	for j, mm := range m.models {
		go func(j int, mm *systray.MenuItem) {
			for range mm.ClickedCh {
				modelClicks <- j
			}
		}(j, mm)
	}
	for {
		select {
		case <-m.openChat.ClickedCh:
			openURL("https://t.me/" + m.bot)
		case <-m.claude.ClickedCh:
			t.app.setEngine(m.bot, "claude")
		case <-m.codex.ClickedCh:
			t.app.setEngine(m.bot, "codex")
		case j := <-modelClicks:
			if j < len(m.modelIDs) {
				t.app.setModel(m.bot, m.engineID, m.modelIDs[j])
			}
		case <-m.folder.ClickedCh:
			if dir := chooseFolder(); dir != "" {
				t.app.setAgentFolder(m.bot, dir)
			}
		case <-m.remove.ClickedCh:
			if confirm("Отключить @" + m.bot + "?\n\nПомощник забудет этого бота и его токен. Сам бот и его чаты останутся. Подключить снова можно с телефона.") {
				_ = t.app.network.RemoveAgent(m.bot)
			}
		}
	}
}

// The agents' lines from the config: names, engines, models with the one in use checked, folders
func (t *Tray) showAgents() {
	cfg, _ := loadConfig()
	home, _ := os.UserHomeDir()
	for i, m := range t.agents {
		if i >= len(cfg.Agents) {
			m.item.Hide()
			m.bot = ""
			continue
		}
		view, _ := cfg.agent(cfg.Agents[i].BotName)
		m.bot, m.engineID = view.BotName, firstNonEmpty(view.Engine, "claude")
		m.item.SetTitle("@" + m.bot + " · " + engineName(m.engineID))
		m.item.Show()
		if m.engineID == "codex" {
			m.codex.Check()
			m.claude.Uncheck()
		} else {
			m.claude.Check()
			m.codex.Uncheck()
		}
		current := currentModel(view, m.engineID)
		m.modelIDs = m.modelIDs[:0]
		for j, mm := range m.models {
			list := engineModels(m.engineID)
			if j >= len(list) {
				mm.Hide()
				continue
			}
			m.modelIDs = append(m.modelIDs, list[j].ID)
			mm.SetTitle(list[j].Name)
			if list[j].ID == current {
				mm.Check()
			} else {
				mm.Uncheck()
			}
			mm.Show()
		}
		dir := view.ProjectsDir
		if home != "" && strings.HasPrefix(dir, home) {
			dir = "~" + strings.TrimPrefix(dir, home)
		}
		m.folder.SetTitle("Папка проектов: " + dir)
	}
	if len(cfg.Agents) > 0 {
		t.agentsTitle.Show()
	} else {
		t.agentsTitle.Hide()
	}
}

// An engine changed here, from the phone or from a bot's button: the checkmarks follow
func (t *Tray) EngineChanged(engine string) {
	t.showAgents()
	t.showStatus()
}

func (t *Tray) setVoice(mode, model string) {
	cfg, _ := loadConfig()
	cfg.Voice = mode
	if model != "" {
		cfg.VoiceModel = model
	}
	_ = saveConfig(cfg)
	if mode == "whisper" {
		downloadModel(modelByID(cfg.VoiceModel))
	}
	t.app.settingsChanged(cfg)
}

// Voice recognition changed: the checkmarks follow
func (t *Tray) VoiceChanged(cfg Config) {
	mode := firstNonEmpty(cfg.Voice, "off")
	set := func(item *systray.MenuItem, on bool) {
		if on {
			item.Check()
		} else {
			item.Uncheck()
		}
	}
	set(t.voiceOff, mode == "off")
	set(t.voiceLight, mode == "whisper" && cfg.VoiceModel != "accurate")
	set(t.voiceAccurate, mode == "whisper" && cfg.VoiceModel == "accurate")
	set(t.voiceGroq, mode == "groq")
}

// The statuses' choice, from the phone or from the menu: the checkmarks follow
func (t *Tray) StatusesChanged(mode string) {
	for item, detailed := range map[*systray.MenuItem]bool{t.statusOff: false, t.statusAll: true} {
		if detailed == (mode != "off") {
			item.Check()
		} else {
			item.Uncheck()
		}
	}
}

func (t *Tray) Waiting(code string) {
	t.bot = ""
	t.status.SetTitle("Telepath · ждёт телефон")
	t.line.SetTitle("Открой Telepath на телефоне:")
	t.where.Show()
	t.code.SetTitle("Код этого компьютера: " + code)
	t.code.Show()
	t.showAgents()
	t.welcome(code, "")
}

func (t *Tray) Paired(bot, engine string) {
	notify("Подключено", "@"+bot+" теперь работает здесь, на "+engineName(engine)+". Напиши ему в Telegram.")
}

// The agents working here, each with its own submenu
func (t *Tray) Working(bots []string, engine string) {
	t.bot = bots[0]
	if len(bots) == 1 {
		t.status.SetTitle("Telepath · 1 агент")
	} else {
		t.status.SetTitle(fmt.Sprintf("Telepath · агентов: %d", len(bots)))
	}
	t.where.Hide()
	t.code.Hide()
	t.showAgents()
	t.showStatus()
	t.welcome("", t.bot)
}

func (t *Tray) showStatus() {
	if topics, running, ok := t.app.status(); ok {
		t.line.SetTitle(fmt.Sprintf("Сейчас работают %d, всего тем %d", running, topics))
	}
}

func (t *Tray) refresh() {
	for range time.Tick(3 * time.Second) {
		if t.bot != "" {
			t.showStatus()
		}
	}
}

func engineName(engine string) string {
	if engine == "codex" {
		return "Codex"
	}
	if engine == "chat" {
		return "Только ответы"
	}
	return "Claude Code"
}

// The greeting, at the very first start: that the helper lives as an icon, and what to do now on the phone (or, when
// already connected, which bot works here)
func (t *Tray) welcome(code, bot string) {
	cfg, _ := loadConfig()
	if cfg.WelcomeShown {
		return
	}
	cfg.WelcomeShown = true
	_ = saveConfig(cfg)
	place := "в строке меню, наверху справа"
	if isWindows {
		place = "у часов, внизу справа"
	}
	text := "Привет! Telepath для компьютера работает тихо, без окон. Он живёт значком " + place + ": там статус, папка проектов и настройки.\n\n"
	if bot == "" {
		text += "Теперь открой Telepath на телефоне: Настройки → Telepath → Агенты. Этот компьютер появится там, нажми «Подключить».\n\nКод этого компьютера: " + code + ". Он должен совпасть с кодом на телефоне."
	} else {
		text += "Компьютер уже подключён: @" + bot + " работает здесь. Пиши ему в Telegram."
	}
	go alert("Telepath для компьютера", text)
}

// One helper per computer: two would both take the bot's messages
func singleInstance() bool {
	l, err := net.Listen("tcp", "127.0.0.1:47431")
	if err != nil {
		return false
	}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	return true
}

func executablePath() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		return real
	}
	return exe
}

// a newer helper is out: a menu item and one notice
func (t *Tray) updateFound(r *helperRelease) {
	t.update.SetTitle("Обновить до " + r.Version)
	t.update.Enable()
	t.update.Show()
	notify("Есть обновление", "Telepath Helper "+r.Version+". Обновить можно в меню значка.")
}
