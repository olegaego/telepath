package main

// Agentgram helper: works as the owner's bot on the owner's computer. Each topic of the bot's chat is a session of
// Claude Code (or Codex) in a project folder. It talks to api.telegram.org with the bot's token and runs the
// official CLIs; it answers only the owner and sends nothing anywhere else.
//
//   agentgram-helper          run; the first time it waits for Agentgram on the same network to connect it
//   agentgram-helper pair     connect again (another bot or owner)
//   agentgram-helper setup    the same by hand: the bot's token and the owner's Telegram id

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

func main() {
	args := map[string]bool{}
	for _, a := range os.Args[1:] {
		args[a] = true
	}
	if args["setup"] {
		setup()
		return
	}
	extendPath()
	logToFile()
	if !singleInstance() {
		fmt.Println("Agentgram для компьютера уже запущен: значок в строке меню.")
		return
	}
	cfg, _ := loadConfig()
	if args["pair"] {
		cfg.BotToken, cfg.OwnerID, cfg.BotName, cfg.PhoneSecret = "", 0, "", ""
		_ = saveConfig(cfg)
	}
	network, err := startNetwork(cfg)
	if err != nil {
		log.Fatal("сеть: ", err)
	}
	// on quit the computer says goodbye on the network, so Agentgram shows it gone at once
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		network.Shutdown()
		os.Exit(0)
	}()
	app := &App{network: network}
	if args["--no-tray"] {
		app.run(cfg)
		return
	}
	runTray(app, cfg)
}

// Started from the menu bar or at login, the helper gets a bare PATH; the engines' CLIs (and node, which runs codex)
// are usually in Homebrew's or the user's own bin
func extendPath() {
	home, _ := os.UserHomeDir()
	extra := []string{"/opt/homebrew/bin", "/usr/local/bin", filepath.Join(home, ".local", "bin")}
	path := os.Getenv("PATH")
	for _, d := range extra {
		if !strings.Contains(string(os.PathListSeparator)+path+string(os.PathListSeparator), string(os.PathListSeparator)+d+string(os.PathListSeparator)) {
			path += string(os.PathListSeparator) + d
		}
	}
	_ = os.Setenv("PATH", path)
}

// The journal also goes to ~/.agentgram/helper.log: from the menu bar there is no terminal to see it in
func logToFile() {
	path := filepath.Join(dataDir(), "helper.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 5<<20 {
		_ = os.Rename(path, path+".old")
	}
	_ = os.MkdirAll(dataDir(), 0o700)
	if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
		log.SetOutput(io.MultiWriter(os.Stderr, f))
	}
}

// The helper's work, the same with the menu-bar icon or without it: waits for the phone, then works as the bot until
// it is disconnected, and waits again
type App struct {
	network *Network
	ui      UI
	mu      sync.Mutex
	helper  *Helper
}

// What the icon's menu shows; nothing when the helper runs without it
type UI interface {
	Waiting(code string)
	Working(bot, engine string)
	Paired(bot, engine string)
}

func (a *App) run(cfg Config) {
	for {
		if cfg.BotToken == "" {
			fmt.Println()
			fmt.Println("Жду Agentgram в этой сети.")
			fmt.Println("В Agentgram: Настройки → Agentgram → Агенты → «" + computerName() + "» → Подключить.")
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
		h := &Helper{cfg: cfg, bot: NewBot(cfg.BotToken), state: loadState(), topics: map[string]*topicWork{}, pending: map[string]*pendingChoice{}}
		a.network.Status = h.status
		me, err := h.bot.GetMe()
		if err != nil {
			log.Println("бот не отвечает: ", err)
			time.Sleep(10 * time.Second)
			continue
		}
		log.Printf("работаю как @%s, хозяин %d, движок %s", me.Username, cfg.OwnerID, cfg.Engine)
		a.mu.Lock()
		a.helper = h
		a.mu.Unlock()
		if a.ui != nil {
			a.ui.Working(me.Username, cfg.Engine)
		}
		stop := make(chan struct{})
		go h.loop(stop)
		<-a.network.Unpaired
		close(stop)
		a.mu.Lock()
		a.helper = nil
		a.mu.Unlock()
		log.Println("отключён")
		cfg, _ = loadConfig()
	}
}

// Topics and running turns of the bot now working, for the menu
func (a *App) status() (topics, running int, ok bool) {
	a.mu.Lock()
	h := a.helper
	a.mu.Unlock()
	if h == nil {
		return 0, 0, false
	}
	st := h.status()
	return st["topics"].(int), st["running"].(int), true
}

// A new projects folder, from the menu: saved, and the working helper lists projects from it at once
func (a *App) setProjectsDir(dir string) {
	cfg, _ := loadConfig()
	cfg.ProjectsDir = dir
	_ = saveConfig(cfg)
	a.mu.Lock()
	h := a.helper
	a.mu.Unlock()
	if h != nil {
		h.mu.Lock()
		h.cfg.ProjectsDir = dir
		h.mu.Unlock()
	}
}

// A turn of the engine this computer works on now
type Turn interface {
	Run(cwd, session, prompt string, ev TurnEvents) TurnResult
	Stop()
}

func (h *Helper) engine() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.cfg.Engine == "codex" {
		return "codex"
	}
	return "claude"
}

func (h *Helper) newTurn() Turn {
	if h.engine() == "codex" {
		return &CodexTurn{}
	}
	return &ClaudeTurn{}
}

// Another engine, from the menu: saved, and the next turns go to it (a turn going now finishes on the old one)
func (a *App) setEngine(engine string) {
	cfg, _ := loadConfig()
	cfg.Engine = engine
	_ = saveConfig(cfg)
	a.network.reannounce(cfg)
	a.mu.Lock()
	h := a.helper
	a.mu.Unlock()
	if h != nil {
		h.mu.Lock()
		h.cfg.Engine = engine
		h.mu.Unlock()
	}
}

func (h *Helper) projectsDir() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.cfg.ProjectsDir
}

// For «Computers» in Agentgram: how many topics and how many of them work right now
func (h *Helper) status() map[string]any {
	h.mu.Lock()
	running := len(h.topics)
	h.mu.Unlock()
	h.state.mu.Lock()
	topics := len(h.state.Topics)
	h.state.mu.Unlock()
	return map[string]any{"topics": topics, "running": running}
}

func setup() {
	in := bufio.NewReader(os.Stdin)
	ask := func(q string) string {
		fmt.Print(q)
		s, _ := in.ReadString('\n')
		return strings.TrimSpace(s)
	}
	cfg, _ := loadConfig()
	cfg.BotToken = ask("Токен бота: ")
	owner, err := strconv.ParseInt(ask("Твой id в Telegram: "), 10, 64)
	if err != nil {
		fmt.Println("id это число")
		os.Exit(1)
	}
	cfg.OwnerID = owner
	if dir := ask("Папка проектов (Enter: " + cfg.ProjectsDir + "): "); dir != "" {
		cfg.ProjectsDir = expandHome(dir)
	}
	if err := saveConfig(cfg); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	fmt.Println("Сохранено в", filepath.Join(dataDir(), "helper.json"))
}

type Helper struct {
	cfg     Config
	bot     *Bot
	state   *State
	mu      sync.Mutex
	topics  map[string]*topicWork     // topics with a turn going
	pending map[string]*pendingChoice // what the buttons of a topic mean
}

type topicWork struct {
	turn  Turn
	queue []string
}

type pendingChoice struct {
	dirs    []string
	options []string
	naming  bool // waiting for the name of a new project
}

func topicKey(chat, thread int64) string {
	return fmt.Sprintf("%d:%d", chat, thread)
}

func (h *Helper) loop(stop chan struct{}) {
	offset := h.state.Offset
	for {
		select {
		case <-stop:
			return
		default:
		}
		ups, err := h.bot.GetUpdates(offset)
		if err != nil {
			var apiErr *APIError
			if errors.As(err, &apiErr) && apiErr.RetryAfter > 0 {
				time.Sleep(time.Duration(apiErr.RetryAfter) * time.Second)
			} else {
				log.Println("getUpdates:", err)
				time.Sleep(5 * time.Second)
			}
			continue
		}
		for _, u := range ups {
			offset = u.UpdateID + 1
			if u.Message != nil {
				h.onMessage(u.Message)
			} else if u.CallbackQuery != nil {
				h.onCallback(u.CallbackQuery)
			}
		}
		if len(ups) > 0 {
			h.state.setOffset(offset)
		}
	}
}

func (h *Helper) isOwner(u *User) bool {
	return u != nil && u.ID == h.cfg.OwnerID
}

func (h *Helper) onMessage(m *Message) {
	if !h.isOwner(m.From) {
		return // strangers' messages are dropped: only the owner can run anything on this computer
	}
	if m.ForumTopicCreated != nil {
		h.askFolder(m.Chat.ID, m.MessageThreadID)
		return
	}
	key := topicKey(m.Chat.ID, m.MessageThreadID)
	text := strings.TrimSpace(firstNonEmpty(m.Text, m.Caption))
	if text == "/stop" {
		h.stop(key)
		return
	}
	h.mu.Lock()
	p := h.pending[key]
	h.mu.Unlock()
	if p != nil && p.naming {
		h.newProject(m.Chat.ID, m.MessageThreadID, text)
		return
	}
	t, ok := h.state.topic(key)
	if !ok {
		h.askFolder(m.Chat.ID, m.MessageThreadID)
		return
	}
	prompt := text
	if files := h.saveFiles(m); len(files) > 0 {
		prompt = strings.TrimSpace(prompt + "\n\nПрислал файлы (лежат на диске):\n" + strings.Join(files, "\n"))
	}
	if prompt == "" {
		return
	}
	h.enqueue(m.Chat.ID, m.MessageThreadID, t, prompt)
}

// The photos and documents the owner sent go to ~/.agentgram/files, and the agent gets their paths
func (h *Helper) saveFiles(m *Message) []string {
	var ids []struct{ id, name string }
	if len(m.Photo) > 0 {
		ids = append(ids, struct{ id, name string }{m.Photo[len(m.Photo)-1].FileID, "photo.jpg"})
	}
	if m.Document != nil {
		ids = append(ids, struct{ id, name string }{m.Document.FileID, firstNonEmpty(m.Document.FileName, "file")})
	}
	if len(ids) == 0 {
		return nil
	}
	dir := filepath.Join(dataDir(), "files", time.Now().Format("20060102-150405")+fmt.Sprintf("-%d", m.MessageID))
	_ = os.MkdirAll(dir, 0o700)
	var paths []string
	for _, f := range ids {
		data, _, err := h.bot.Download(f.id)
		if err != nil {
			log.Println("download:", err)
			continue
		}
		p := filepath.Join(dir, regexp.MustCompile(`[^\w.\-]+`).ReplaceAllString(f.name, "_"))
		if os.WriteFile(p, data, 0o600) == nil {
			paths = append(paths, p)
		}
	}
	return paths
}

func (h *Helper) folders() []string {
	entries, err := os.ReadDir(h.projectsDir())
	if err != nil {
		return nil
	}
	var dirs []string
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			dirs = append(dirs, filepath.Join(h.projectsDir(), e.Name()))
		}
	}
	fresh := func(d string) time.Time {
		best := time.Time{}
		for _, p := range []string{d, filepath.Join(d, ".git", "index")} {
			if st, err := os.Stat(p); err == nil && st.ModTime().After(best) {
				best = st.ModTime()
			}
		}
		return best
	}
	sort.Slice(dirs, func(i, j int) bool { return fresh(dirs[i]).After(fresh(dirs[j])) })
	if len(dirs) > 12 {
		dirs = dirs[:12]
	}
	return dirs
}

func (h *Helper) askFolder(chat, thread int64) {
	dirs := h.folders()
	var rows [][]Button
	for i, d := range dirs {
		rows = append(rows, []Button{{Text: filepath.Base(d), CallbackData: fmt.Sprintf("dir:%d", i)}})
	}
	rows = append(rows, []Button{{Text: "+ Новый проект", CallbackData: "new"}})
	h.mu.Lock()
	h.pending[topicKey(chat, thread)] = &pendingChoice{dirs: dirs}
	h.mu.Unlock()
	_, _ = h.bot.Send(chat, thread, "С какой папкой работаем?", &Keyboard{InlineKeyboard: rows})
}

var projectName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func (h *Helper) newProject(chat, thread int64, name string) {
	key := topicKey(chat, thread)
	if !projectName.MatchString(name) {
		_, _ = h.bot.Send(chat, thread, "Имя папки: латиница, цифры, точка, дефис или подчёркивание. Ещё раз?", nil)
		return
	}
	path := filepath.Join(h.projectsDir(), name)
	if fileExists(path) {
		_, _ = h.bot.Send(chat, thread, "Такая папка уже есть, выбери её в списке.", nil)
		return
	}
	if err := os.MkdirAll(path, 0o755); err != nil {
		_, _ = h.bot.Send(chat, thread, "Не вышло создать папку: "+err.Error(), nil)
		return
	}
	_ = exec.Command("git", "init", "-q", path).Run()
	h.mu.Lock()
	delete(h.pending, key)
	h.mu.Unlock()
	h.state.setTopic(key, TopicState{Cwd: path})
	_, _ = h.bot.Send(chat, thread, "Новый проект "+name+". Пиши, что делаем.", nil)
}

func (h *Helper) onCallback(q *CallbackQuery) {
	if !h.isOwner(&q.From) || q.Message == nil {
		_ = h.bot.Answer(q.ID, "")
		return
	}
	chat, thread := q.Message.Chat.ID, q.Message.MessageThreadID
	key := topicKey(chat, thread)
	h.mu.Lock()
	p := h.pending[key]
	h.mu.Unlock()
	_ = h.bot.Answer(q.ID, "")
	switch {
	case q.Data == "new":
		h.mu.Lock()
		h.pending[key] = &pendingChoice{naming: true}
		h.mu.Unlock()
		_ = h.bot.Edit(chat, q.Message.MessageID, "Как назвать папку нового проекта? Латиницей, например my-app.", nil)
	case strings.HasPrefix(q.Data, "dir:") && p != nil:
		i, _ := strconv.Atoi(strings.TrimPrefix(q.Data, "dir:"))
		if i < 0 || i >= len(p.dirs) {
			return
		}
		h.mu.Lock()
		delete(h.pending, key)
		h.mu.Unlock()
		h.state.setTopic(key, TopicState{Cwd: p.dirs[i]})
		_ = h.bot.Edit(chat, q.Message.MessageID, "Работаем в "+filepath.Base(p.dirs[i])+". Пиши, что делаем.", nil)
	case strings.HasPrefix(q.Data, "ch:") && p != nil:
		i, _ := strconv.Atoi(strings.TrimPrefix(q.Data, "ch:"))
		if i < 0 || i >= len(p.options) {
			return
		}
		choice := p.options[i]
		_ = h.bot.Edit(chat, q.Message.MessageID, q.Message.Text+"\n\n→ "+choice, nil)
		if t, ok := h.state.topic(key); ok {
			h.enqueue(chat, thread, t, choice)
		}
	}
}

func (h *Helper) stop(key string) {
	h.mu.Lock()
	w := h.topics[key]
	if w != nil {
		w.queue = nil
	}
	h.mu.Unlock()
	if w != nil && w.turn != nil {
		w.turn.Stop()
	}
}

// One turn at a time in a topic; what comes meanwhile waits and goes next
func (h *Helper) enqueue(chat, thread int64, t TopicState, prompt string) {
	key := topicKey(chat, thread)
	turn := h.newTurn() // before the lock: choosing the engine takes it too
	h.mu.Lock()
	if w := h.topics[key]; w != nil {
		w.queue = append(w.queue, prompt)
		h.mu.Unlock()
		_, _ = h.bot.Send(chat, thread, "Закончу текущее и возьмусь.", nil)
		return
	}
	w := &topicWork{turn: turn}
	h.topics[key] = w
	h.mu.Unlock()
	go func() {
		for prompt != "" {
			current, _ := h.state.topic(key)
			h.runTurn(chat, thread, key, current, w.turn, prompt)
			h.mu.Lock()
			prompt = ""
			if len(w.queue) > 0 {
				prompt, w.queue = w.queue[0], w.queue[1:]
			} else {
				delete(h.topics, key)
			}
			h.mu.Unlock()
		}
	}()
}

func (h *Helper) runTurn(chat, thread int64, key string, t TopicState, turn Turn, prompt string) {
	engine := h.engine()
	log.Printf("ход: тема %s, %s, папка %s", key, engine, t.Cwd)
	if !filepath.IsAbs(t.Cwd) {
		t.Cwd = filepath.Join(h.projectsDir(), t.Cwd)
	}
	session := t.Session
	if firstNonEmpty(t.Engine, "claude") != engine {
		// the topic's session is the other engine's: this one starts its own
		session = ""
	}
	draft, _ := h.bot.Send(chat, thread, "… Думаю", nil)
	var steps []string
	var last time.Time
	var mu sync.Mutex
	show := func(force bool) {
		mu.Lock()
		defer mu.Unlock()
		// at most every 3 seconds: editing faster gets the bot rate-limited by Telegram
		if draft.MessageID == 0 || (!force && time.Since(last) < 3*time.Second) {
			return
		}
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
		if len(lines) > 0 {
			_ = h.bot.Edit(chat, draft.MessageID, strings.Join(lines, "\n"), nil)
			last = time.Now()
		}
	}
	result := turn.Run(t.Cwd, session, prompt, TurnEvents{
		Step: func(s string) {
			mu.Lock()
			steps = append(steps, s)
			mu.Unlock()
			show(false)
		},
		Session: func(id string) {
			if id != session {
				session = id
				h.state.setSession(key, id, engine)
			}
		},
	})
	if draft.MessageID != 0 {
		_ = h.bot.Delete(chat, draft.MessageID)
	}
	if result.Error != "" {
		log.Printf("ход: тема %s, ошибка: %s", key, trim(result.Error, 300))
		_, _ = h.bot.Send(chat, thread, "Ошибка: "+trim(result.Error, 3500), nil)
		return
	}
	text, options := choices(result.Text)
	text = firstNonEmpty(text, "Готово.")
	var kb *Keyboard
	if len(options) > 0 {
		kb = &Keyboard{}
		for j, o := range options {
			kb.InlineKeyboard = append(kb.InlineKeyboard, []Button{{Text: o, CallbackData: fmt.Sprintf("ch:%d", j)}})
		}
		h.mu.Lock()
		h.pending[key] = &pendingChoice{options: options}
		h.mu.Unlock()
	}
	// the engine writes Markdown: sent as a rich message, as Telegram shows it; if not taken, plain text in parts
	if _, err := h.bot.SendRich(chat, thread, trim(text, 30000), kb); err == nil {
		return
	}
	parts := split(text, 4000)
	for i, part := range parts {
		var last *Keyboard
		if i == len(parts)-1 {
			last = kb
		}
		_, _ = h.bot.Send(chat, thread, part, last)
	}
}

var choicesBlock = regexp.MustCompile("(?s)```варианты\\s*\\n(.*?)```")

// A ```варианты``` block at the end of an answer becomes buttons
func choices(text string) (string, []string) {
	m := choicesBlock.FindStringSubmatchIndex(text)
	if m == nil {
		return text, nil
	}
	var options []string
	for _, line := range strings.Split(text[m[2]:m[3]], "\n") {
		if line = strings.TrimSpace(line); line != "" && len(options) < 8 {
			options = append(options, trim(line, 60))
		}
	}
	return strings.TrimSpace(text[:m[0]] + text[m[1]:]), options
}

func split(text string, size int) []string {
	var parts []string
	for utf8.RuneCountInString(text) > size {
		r := []rune(text)
		cut := size
		if i := strings.LastIndex(string(r[:size]), "\n"); i > size/2 {
			cut = utf8.RuneCountInString(string(r[:size])[:i])
		}
		parts = append(parts, string(r[:cut]))
		text = strings.TrimLeft(string(r[cut:]), "\n")
	}
	return append(parts, text)
}

func trim(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n-1]) + "…"
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func homeDir() string {
	home, _ := os.UserHomeDir()
	return home
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(homeDir(), p[2:])
	}
	return p
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
