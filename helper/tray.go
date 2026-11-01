package main

import (
	_ "embed"
	"fmt"
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
	app      *App
	status   *systray.MenuItem
	line     *systray.MenuItem
	where    *systray.MenuItem
	code     *systray.MenuItem
	openChat *systray.MenuItem
	engine   *systray.MenuItem
	claude   *systray.MenuItem
	codex    *systray.MenuItem
	folder   *systray.MenuItem
	login    *systray.MenuItem
	unpair   *systray.MenuItem
	bot      string
	engineID string
}

func runTray(app *App, cfg Config) {
	t := &Tray{app: app}
	app.ui = t
	systray.Run(func() { t.ready(cfg) }, nil)
}

func (t *Tray) ready(cfg Config) {
	systray.SetTemplateIcon(menubarIcon, trayIcon)
	systray.SetTooltip("Agentgram")

	t.status = systray.AddMenuItem("Agentgram", "")
	t.status.Disable()
	t.line = systray.AddMenuItem("", "")
	t.line.Disable()
	t.where = systray.AddMenuItem("Настройки → Agentgram → Агенты", "")
	t.where.Disable()
	t.code = systray.AddMenuItem("", "")
	t.code.Disable()
	t.openChat = systray.AddMenuItem("Открыть чат в Telegram", "")
	systray.AddSeparator()
	t.engine = systray.AddMenuItem("Движок", "")
	t.claude = t.engine.AddSubMenuItemCheckbox("Claude Code", "", true)
	t.codex = t.engine.AddSubMenuItemCheckbox("Codex (скоро)", "", false)
	t.codex.Disable()
	t.folder = systray.AddMenuItem("", "")
	t.showFolder(cfg.ProjectsDir)
	t.login = systray.AddMenuItemCheckbox("Запускать при входе", "", autostartEnabled())
	systray.AddSeparator()
	t.unpair = systray.AddMenuItem("Отключить бота…", "")
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
			case <-t.openChat.ClickedCh:
				openURL("https://t.me/" + t.bot)
			case <-t.claude.ClickedCh:
				t.claude.Check()
			case <-t.folder.ClickedCh:
				if dir := chooseFolder(); dir != "" {
					t.app.setProjectsDir(dir)
					t.showFolder(dir)
				}
			case <-t.login.ClickedCh:
				on := !t.login.Checked()
				if setAutostart(on) == nil {
					if on {
						t.login.Check()
					} else {
						t.login.Uncheck()
					}
				}
			case <-t.unpair.ClickedCh:
				if confirm("Отключить @" + t.bot + "?\n\nПомощник забудет бота и его токен. Сам бот и его чаты останутся. Подключить снова можно с телефона.") {
					_ = t.app.network.Unpair()
				}
			case <-quit.ClickedCh:
				systray.Quit()
				os.Exit(0)
			}
		}
	}()
	go t.refresh()
	go t.app.run(cfg)
}

func (t *Tray) showFolder(dir string) {
	home, _ := os.UserHomeDir()
	if home != "" && strings.HasPrefix(dir, home) {
		dir = "~" + strings.TrimPrefix(dir, home)
	}
	t.folder.SetTitle("Папка проектов: " + dir)
}

func (t *Tray) Waiting(code string) {
	t.bot = ""
	t.status.SetTitle("Agentgram · ждёт телефон")
	t.line.SetTitle("Открой Agentgram на телефоне:")
	t.where.Show()
	t.code.SetTitle("Код этого компьютера: " + code)
	t.code.Show()
	t.openChat.Hide()
	t.unpair.Hide()
	welcome(code)
}

func (t *Tray) Paired(bot, engine string) {
	notify("Подключено", "@"+bot+" теперь работает здесь, на "+engineName(engine)+". Напиши ему в Telegram.")
}

func (t *Tray) Working(bot, engine string) {
	t.bot, t.engineID = bot, engine
	t.status.SetTitle("@" + bot + " · работает")
	t.where.Hide()
	t.code.Hide()
	t.openChat.Show()
	t.unpair.Show()
	t.showStatus()
}

func (t *Tray) showStatus() {
	if topics, running, ok := t.app.status(); ok {
		t.line.SetTitle(fmt.Sprintf("%s · сейчас работают %d, всего тем %d", engineName(t.engineID), running, topics))
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
	return "Claude Code"
}

// The greeting, once per start while the computer is not connected: where the icon is and what to do on the phone
var welcomed bool

func welcome(code string) {
	if welcomed {
		return
	}
	welcomed = true
	place := "в строке меню наверху"
	if isWindows {
		place = "у часов внизу"
	}
	go alert("Agentgram для компьютера запущен", "Он живёт значком "+place+".\n\nТеперь открой Agentgram на телефоне: Настройки → Agentgram → Агенты. Этот компьютер появится там, нажми «Подключить».\n\nКод этого компьютера: "+code+". Он должен совпасть с кодом на телефоне.")
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
