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
		fmt.Println("Telepath для компьютера уже запущен: значок в строке меню.")
		return
	}
	cfg, _ := loadConfig()
	if args["pair"] {
		cfg.Agents, cfg.PhoneSecret = nil, ""
		_ = saveConfig(cfg)
		cfg, _ = loadConfig()
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
	app := &App{network: network, helpers: map[string]*running{}}
	network.OnEngine = app.setEngine
	network.OnStatuses = app.setStatuses
	network.OnSettings = app.settingsChanged
	network.Topics = func() []TopicStatus {
		out := []TopicStatus{}
		for _, h := range app.all() {
			h.mu.Lock()
			bot := h.cfg.BotName
			h.mu.Unlock()
			for _, t := range h.board.list() {
				t.Bot = bot
				out = append(out, t)
			}
		}
		return out
	}
	network.Status = func(bot string) map[string]any {
		if h := app.helperOf(bot); h != nil {
			return h.status()
		}
		return map[string]any{"topics": 0, "running": 0}
	}
	network.OnStop = func(bot string, chat, thread int64) {
		if h := app.helperOf(bot); h != nil {
			h.stop(topicKey(chat, thread))
		}
	}
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

// A turn of the engine this computer works on now
type Turn interface {
	Run(cwd, session, prompt string, ev TurnEvents) TurnResult
	Stop()
}

// A turn whose engine lives between messages (Claude Code now): the topic keeps it, listens to it while idle and
// closes it after a quiet while
type LiveTurn interface {
	Turn
	Woke() bool
	Wake() <-chan struct{}
	Close()
}

// A topic's living engine is closed after this long without messages; the next one starts it again with its session
var liveIdle = 30 * time.Minute

func (h *Helper) engine() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.cfg.Engine == "codex" || h.cfg.Engine == "chat" {
		return h.cfg.Engine
	}
	return "claude"
}

func (h *Helper) newTurn() Turn {
	engine := h.engine()
	h.mu.Lock()
	model := h.cfg.Models[engine]
	h.mu.Unlock()
	switch engine {
	case "codex":
		return &CodexLiveTurn{Model: model}
	case "chat":
		h.mu.Lock()
		key := h.cfg.ChatKey
		h.mu.Unlock()
		return &ChatTurn{Model: model, Key: key}
	}
	return &ClaudeLiveTurn{Model: model}
}

// what the topic's turn is made with: a change of the engine or its model makes a new one
func (h *Helper) turnKind() string {
	engine := h.engine()
	h.mu.Lock()
	defer h.mu.Unlock()
	return engine + "/" + h.cfg.Models[engine]
}

func (h *Helper) statusesMode() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return firstNonEmpty(h.cfg.Statuses, "off")
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
	return map[string]any{"topics": topics, "running": running, "today_turns": turnsToday()}
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
	if me, err := NewBot(cfg.BotToken).GetMe(); err == nil {
		cfg.BotName = me.Username
	}
	cfg.putAgent(cfg)
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
	cfg          Config
	bot          *Bot
	state        *State
	mu           sync.Mutex
	topics       map[string]*topicWork     // topics with a turn going
	pending      map[string]*pendingChoice // what the buttons of a topic mean
	switchEngine func(engine string)       // the app's own switch: saved, announced, shown in the menu
	board        *statusBoard              // what each topic does, for Agentgram
	drafts       *draftBudget              // one budget of drafts per chat
	lang         string                    // the owner's Telegram language, from their last message: what the bot speaks
}

// The bot's own words in the owner's language: Russian for «ru», English for any other
func (h *Helper) t(ru, en string) string {
	h.mu.Lock()
	lang := firstNonEmpty(h.cfg.Lang, h.lang)
	h.mu.Unlock()
	if strings.HasPrefix(lang, "ru") {
		return ru
	}
	return en
}

func (h *Helper) heard(u *User) {
	if u != nil && u.LanguageCode != "" {
		h.mu.Lock()
		changed := h.lang != u.LanguageCode
		h.lang = u.LanguageCode
		h.mu.Unlock()
		if changed {
			log.Printf("@%s: язык владельца %s", h.cfg.BotName, u.LanguageCode)
		}
	}
}

type topicWork struct {
	turn  Turn
	kind  string // turnKind() of the turn
	queue []string
	busy  bool          // a turn goes
	wake  chan struct{} // a message was queued
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
			h.closeTopics()
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

func (h *Helper) voiceTurn(m *Message, t TopicState) {
	h.bot.Typing(m.Chat.ID, m.MessageThreadID)
	text, err := h.transcribe(m.Voice.FileID)
	switch {
	case errors.Is(err, errVoiceOff):
		_, _ = h.bot.Send(m.Chat.ID, m.MessageThreadID, h.t("Голосовые выключены. Включи «Распознавание» в Telepath (Настройки → Telepath) или в меню значка на компьютере.", "Voice messages are off. Turn on Recognition in Telepath (Settings → Telepath) or in the icon's menu on the computer."), nil)
	case err != nil:
		log.Printf("голосовое: %v", err)
		_, _ = h.bot.Send(m.Chat.ID, m.MessageThreadID, h.t("Не распознал голосовое: ", "Could not recognize the voice message: ")+err.Error(), nil)
	case text == "":
		_, _ = h.bot.Send(m.Chat.ID, m.MessageThreadID, h.t("В голосовом не нашлось слов.", "No words in the voice message."), nil)
	default:
		if m.ForwardOrigin != nil {
			text = "Пересланное голосовое: " + text
		}
		h.enqueue(m.Chat.ID, m.MessageThreadID, t, text)
	}
}

// The owner and the people the owner let in; everyone else is dropped
func (h *Helper) isOwner(u *User) bool {
	if u == nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if u.ID == h.cfg.OwnerID {
		return true
	}
	for _, p := range h.cfg.Allowed {
		if p.ID == u.ID {
			return true
		}
	}
	return false
}

func (h *Helper) onMessage(m *Message) {
	if !h.isOwner(m.From) {
		return // strangers' messages are dropped: only the owner can run anything on this computer
	}
	h.heard(m.From)
	if m.ForumTopicCreated != nil {
		if h.engine() != "chat" {
			h.askFolder(m.Chat.ID, m.MessageThreadID)
		}
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
	if !ok && h.engine() == "chat" {
		// «Только ответы» needs no folder: a new topic starts talking at once
		t = TopicState{Cwd: h.projectsDir()}
		h.state.setTopic(key, t)
		ok = true
	}
	if !ok {
		h.askFolder(m.Chat.ID, m.MessageThreadID)
		return
	}
	prompt := text
	if files := h.saveFiles(m); len(files) > 0 {
		prompt = strings.TrimSpace(prompt + "\n\nПрислал файлы (лежат на диске):\n" + strings.Join(files, "\n"))
	}
	if prompt == "" && m.Voice != nil {
		// a voice message, the owner's own or forwarded: its words, recognized here, go to the agent
		go h.voiceTurn(m, t)
		return
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
	rows = append(rows, []Button{{Text: h.t("+ Новый проект", "+ New Project"), CallbackData: "new"}})
	h.mu.Lock()
	h.pending[topicKey(chat, thread)] = &pendingChoice{dirs: dirs}
	h.mu.Unlock()
	_, _ = h.bot.Send(chat, thread, h.t("С какой папкой работаем?", "Which folder are we working in?"), &Keyboard{InlineKeyboard: rows})
}

var projectName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func (h *Helper) newProject(chat, thread int64, name string) {
	key := topicKey(chat, thread)
	if !projectName.MatchString(name) {
		_, _ = h.bot.Send(chat, thread, h.t("Имя папки: латиница, цифры, точка, дефис или подчёркивание. Ещё раз?", "A folder name: Latin letters, digits, dot, dash or underscore. Once more?"), nil)
		return
	}
	path := filepath.Join(h.projectsDir(), name)
	if fileExists(path) {
		_, _ = h.bot.Send(chat, thread, h.t("Такая папка уже есть, выбери её в списке.", "This folder already exists, pick it in the list."), nil)
		return
	}
	if err := os.MkdirAll(path, 0o755); err != nil {
		_, _ = h.bot.Send(chat, thread, h.t("Не вышло создать папку: ", "Could not create the folder: ")+err.Error(), nil)
		return
	}
	_ = exec.Command("git", "init", "-q", path).Run()
	h.mu.Lock()
	delete(h.pending, key)
	h.mu.Unlock()
	h.state.setTopic(key, TopicState{Cwd: path})
	_, _ = h.bot.Send(chat, thread, h.t("Новый проект "+name+". Пиши, что делаем.", "New project "+name+". Write what we do."), nil)
}

func (h *Helper) onCallback(q *CallbackQuery) {
	if !h.isOwner(&q.From) || q.Message == nil {
		_ = h.bot.Answer(q.ID, "")
		return
	}
	h.heard(&q.From)
	chat, thread := q.Message.Chat.ID, q.Message.MessageThreadID
	key := topicKey(chat, thread)
	h.mu.Lock()
	p := h.pending[key]
	h.mu.Unlock()
	_ = h.bot.Answer(q.ID, "")
	// What a button means comes from the message itself, so buttons still work after the helper restarts
	pressed := ""
	if q.Message.ReplyMarkup != nil {
		for _, row := range q.Message.ReplyMarkup.InlineKeyboard {
			for _, b := range row {
				if b.CallbackData == q.Data {
					pressed = b.Text
				}
			}
		}
	}
	chosen := func() {
		if pressed != "" {
			_ = h.bot.EditKeyboard(chat, q.Message.MessageID, &Keyboard{InlineKeyboard: [][]Button{{{Text: pressed, CallbackData: "done", Style: "success"}}}})
		}
	}
	switch {
	case q.Data == "done":
	case q.Data == "new":
		h.mu.Lock()
		h.pending[key] = &pendingChoice{naming: true}
		h.mu.Unlock()
		_ = h.bot.Edit(chat, q.Message.MessageID, h.t("Как назвать папку нового проекта? Латиницей, например my-app.", "What to call the new project's folder? In Latin letters, for example my-app."), nil)
	case strings.HasPrefix(q.Data, "dir:"):
		dir := ""
		if i, err := strconv.Atoi(strings.TrimPrefix(q.Data, "dir:")); err == nil && p != nil && i >= 0 && i < len(p.dirs) {
			dir = p.dirs[i]
		} else if pressed != "" {
			dir = filepath.Join(h.projectsDir(), pressed)
		}
		if dir == "" || !fileExists(dir) {
			return
		}
		h.mu.Lock()
		delete(h.pending, key)
		h.mu.Unlock()
		h.state.setTopic(key, TopicState{Cwd: dir})
		_ = h.bot.Edit(chat, q.Message.MessageID, h.t("Работаем в "+filepath.Base(dir)+". Пиши, что делаем.", "Working in "+filepath.Base(dir)+". Write what we do."), nil)
	case strings.HasPrefix(q.Data, "engine:"):
		engine := strings.TrimPrefix(q.Data, "engine:")
		if (engine == "claude" || engine == "codex") && h.switchEngine != nil {
			h.switchEngine(engine)
			chosen()
			_, _ = h.bot.Send(chat, thread, h.t("Теперь "+engineName(engine)+". Следующее сообщение в теме начнёт новую сессию.", "Now "+engineName(engine)+". The next message in the topic starts a new session."), nil)
		}
	case strings.HasPrefix(q.Data, "ch:"):
		// the pressed button's own text: an older message's buttons mean what they say, not the newest choice
		choice := pressed
		if i, err := strconv.Atoi(strings.TrimPrefix(q.Data, "ch:")); choice == "" && err == nil && p != nil && i >= 0 && i < len(p.options) {
			choice = p.options[i]
		}
		if choice == "" {
			return
		}
		h.mu.Lock()
		delete(h.pending, key)
		h.mu.Unlock()
		pressed = choice
		chosen()
		if t, ok := h.state.topic(key); ok {
			h.enqueue(chat, thread, t, choice)
		}
	}
}

// From 80% of a window the bot says so once, with a button to the other engine when it is installed here
func (h *Helper) warnLimits(chat, thread int64, engine string, windows []LimitWindow) {
	other := "codex"
	if engine == "codex" {
		other = "claude"
	}
	for _, w := range windows {
		text := h.t(fmt.Sprintf("⚠️ %s: %s окно лимита на **%.0f%%**", engineName(engine), windowWord(w.Name), w.Percent), fmt.Sprintf("⚠️ %s: the %s limit is at **%.0f%%**", engineName(engine), windowWordEn(w.Name), w.Percent))
		if r := h.t(resetText(w.ResetsAt), resetTextEn(w.ResetsAt)); r != "" {
			text += ", " + r
		}
		var kb *Keyboard
		if engineInstalled(other) {
			kb = &Keyboard{InlineKeyboard: [][]Button{{{Text: h.t("Переключить на ", "Switch to ") + engineName(other), CallbackData: "engine:" + other}}}}
		}
		if _, err := h.bot.SendRich(chat, thread, text+".", kb); err != nil {
			_, _ = h.bot.Send(chat, thread, strings.ReplaceAll(text, "**", "")+".", kb)
		}
	}
}

func (h *Helper) elapsed(d time.Duration) string {
	sec := int(d.Seconds())
	if sec >= 60 {
		return h.t(fmt.Sprintf("%d мин %d с", sec/60, sec%60), fmt.Sprintf("%d min %d s", sec/60, sec%60))
	}
	return h.t(fmt.Sprintf("%d с", sec), fmt.Sprintf("%d s", sec))
}

func engineInstalled(engine string) bool {
	if engine == "codex" {
		return codexInstalled()
	}
	if engine == "chat" {
		cfg, _ := loadConfig()
		return cfg.ChatKey != ""
	}
	return claudeBinary() != "claude"
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

// One turn at a time in a topic; what comes meanwhile waits and goes next. The topic stays with its engine between
// messages: a turn the engine starts by itself (its background task finished) goes to the topic as its own answer.
func (h *Helper) enqueue(chat, thread int64, t TopicState, prompt string) {
	key := topicKey(chat, thread)
	h.mu.Lock()
	if w := h.topics[key]; w != nil {
		w.queue = append(w.queue, prompt)
		queued := len(w.queue)
		busy := w.busy
		h.mu.Unlock()
		select {
		case w.wake <- struct{}{}:
		default:
		}
		if busy {
			h.board.set(key, func(s *TopicStatus) { s.Queued = queued })
			_, _ = h.bot.SendQuiet(chat, thread, h.t("Закончу текущее и возьмусь.", "I'll finish the current one and take it."))
		}
		return
	}
	w := &topicWork{queue: []string{prompt}, wake: make(chan struct{}, 1)}
	h.topics[key] = w
	h.mu.Unlock()
	go h.topicLoop(chat, thread, key, w)
}

// The topic's own loop: the queued messages one by one, and while there are none, what its engine says by itself
func (h *Helper) topicLoop(chat, thread int64, key string, w *topicWork) {
	idle := time.NewTimer(liveIdle)
	defer idle.Stop()
	for {
		kind := h.turnKind()
		h.mu.Lock()
		if w.turn == nil || w.kind != kind {
			if live, ok := w.turn.(LiveTurn); ok {
				go live.Close()
			}
			h.mu.Unlock()
			turn := h.newTurn()
			h.mu.Lock()
			w.turn, w.kind = turn, kind
		}
		live, isLive := w.turn.(LiveTurn)
		prompt, background := "", false
		if isLive && live.Woke() {
			// what the engine began by itself goes first: the next message must get its own answer
			background = true
		} else if len(w.queue) > 0 {
			prompt, w.queue = w.queue[0], w.queue[1:]
		}
		if !background && prompt == "" {
			if !isLive {
				delete(h.topics, key)
				h.mu.Unlock()
				return
			}
			h.mu.Unlock()
			select {
			case <-w.wake:
			case <-live.Wake():
			case <-idle.C:
				h.mu.Lock()
				quiet := len(w.queue) == 0 && !live.Woke()
				if quiet {
					delete(h.topics, key)
				}
				h.mu.Unlock()
				if quiet {
					live.Close()
					return
				}
			}
			continue
		}
		w.busy = true
		queued := len(w.queue)
		turn := w.turn
		h.mu.Unlock()
		h.board.set(key, func(s *TopicStatus) { s.Queued = queued })
		current, _ := h.state.topic(key)
		h.runTurn(chat, thread, key, current, turn, prompt)
		h.mu.Lock()
		w.busy = false
		h.mu.Unlock()
		if !idle.Stop() {
			select {
			case <-idle.C:
			default:
			}
		}
		idle.Reset(liveIdle)
	}
}

// sendPhotos sends the answer's pictures before its text: one as a photo, several as an album; a picture that could
// not be made is told in the text
func (h *Helper) sendPhotos(chat, thread int64, refs []photoRef, text *string) {
	var names []string
	var files [][]byte
	for _, ref := range refs {
		data, name, err := renderPhoto(ref)
		if err != nil {
			log.Printf("фото %s: %v", ref.Path, err)
			*text += fmt.Sprintf("\n\n"+h.t("(не вышло показать %s)", "(could not show %s)"), filepath.Base(ref.Path))
			continue
		}
		names, files = append(names, name), append(files, data)
	}
	if len(files) == 1 {
		_ = h.bot.SendPhoto(chat, thread, names[0], files[0])
	} else if len(files) > 1 {
		_ = h.bot.SendAlbum(chat, thread, names, files)
	}
}

// closeTopics ends the topics' living engines, when the helper or its agent stops
func (h *Helper) closeTopics() {
	h.mu.Lock()
	var lives []LiveTurn
	for _, w := range h.topics {
		if live, ok := w.turn.(LiveTurn); ok {
			lives = append(lives, live)
		}
	}
	h.mu.Unlock()
	for _, live := range lives {
		live.Close()
	}
}

func (h *Helper) runTurn(chat, thread int64, key string, t TopicState, turn Turn, prompt string) {
	engine := h.engine()
	log.Printf("ход: тема %s, %s, папка %s", key, engine, t.Cwd)
	started := time.Now()
	countTurn(started)
	var warnings []LimitWindow
	if !filepath.IsAbs(t.Cwd) {
		t.Cwd = filepath.Join(h.projectsDir(), t.Cwd)
	}
	// the topic's folder is gone (renamed, deleted): ask for one again rather than fail
	if st, err := os.Stat(t.Cwd); err != nil || !st.IsDir() {
		log.Printf("ход: тема %s, папки %s нет, спрашиваю заново", key, t.Cwd)
		h.askFolder(chat, thread)
		return
	}
	session := t.Session
	if firstNonEmpty(t.Engine, "claude") != engine {
		// the topic's session is the other engine's: this one starts its own
		session = ""
	}
	// «Подробные» statuses away from home: the steps streamed as the bot's live draft in the topic, sent only when
	// they change (and again before the draft expires), through the chat's budget
	withDraft := h.statusesMode() != "off"
	draftID := started.UnixNano()%1_000_000_000 + 1
	h.board.set(key, func(s *TopicStatus) {
		s.Chat, s.Thread, s.State, s.Detail, s.Since, s.Engine, s.Steps = chat, thread, "working", "", started.Unix(), engine, nil
	})
	var steps []string
	var stepTimes []time.Time
	var shown string
	var lastShown time.Time
	var mu sync.Mutex
	finished := false
	show := func() {
		mu.Lock()
		text := draftText(steps)
		if text == "" {
			text = "… Думаю"
		}
		due := withDraft && !finished && time.Since(started) >= draftAfter && (text != shown || time.Since(lastShown) >= draftKeep)
		mu.Unlock()
		if !due || !h.drafts.take(chat) {
			return
		}
		if err := h.bot.SendDraft(chat, thread, draftID, text); err != nil {
			h.drafts.obey(chat, err)
			return
		}
		mu.Lock()
		shown, lastShown = text, time.Now()
		mu.Unlock()
	}
	ticking := make(chan struct{})
	go func() {
		tick := time.NewTicker(time.Second)
		defer tick.Stop()
		seconds := 0
		h.bot.Typing(chat, thread)
		for {
			select {
			case <-ticking:
				return
			case <-tick.C:
				show()
				// «typing…» in the topic while the agent works: Telegram shows it about 5 s, so every 4 s
				seconds++
				if seconds%4 == 0 {
					h.bot.Typing(chat, thread)
				}
			}
		}
	}()
	result := turn.Run(t.Cwd, session, prompt, TurnEvents{
		Step: func(text string) {
			now := time.Now()
			mu.Lock()
			steps = append(steps, text)
			stepTimes = append(stepTimes, now)
			all := make([]StatusStep, len(steps))
			for i, st := range steps {
				end := now
				if i+1 < len(stepTimes) {
					end = stepTimes[i+1]
				}
				all[i] = StatusStep{Text: st, Secs: int(end.Sub(stepTimes[i]).Seconds())}
			}
			mu.Unlock()
			h.board.set(key, func(s *TopicStatus) {
				s.Detail, s.Steps = text, all
			})
		},
		Session: func(id string) {
			if id != session {
				session = id
				h.state.setSession(key, id, engine)
			}
		},
		Limits: func(l EngineLimits) {
			warnings = append(warnings, saveLimits(engine, l)...)
		},
		Context: func(used, max int) {
			h.board.set(key, func(s *TopicStatus) {
				s.Context = &ContextUse{Used: used, Max: max}
			})
		},
	})
	close(ticking)
	mu.Lock()
	finished = true
	mu.Unlock()
	if result.Error != "" {
		h.board.set(key, func(s *TopicStatus) {
			s.State, s.Detail, s.Since = "error", trim(result.Error, 200), time.Now().Unix()
		})
		log.Printf("ход: тема %s, ошибка: %s", key, trim(result.Error, 300))
		_, _ = h.bot.Send(chat, thread, h.t("Ошибка: ", "Error: ")+trim(result.Error, 3500), nil)
		return
	}
	if c := result.Compacted; c != nil {
		_, _ = h.bot.Send(chat, thread, h.compactedText(*c), nil)
		if strings.TrimSpace(result.Text) == "" {
			// «/compact» alone: the line says it all
			h.board.set(key, func(s *TopicStatus) {
				s.State, s.Detail, s.Since = "idle", "", time.Now().Unix()
			})
			return
		}
	}
	text, refs := takePhotos(result.Text, t.Cwd)
	text, options := choices(text)
	h.sendPhotos(chat, thread, refs, &text)
	h.board.set(key, func(s *TopicStatus) {
		// a question or choices: the agent waits for the owner; else the topic is idle until the next message
		s.State, s.Detail, s.Since = "idle", "", time.Now().Unix()
		if len(options) > 0 || strings.HasSuffix(strings.TrimSpace(text), "?") {
			s.State = "waiting_you"
		}
	})
	text = firstNonEmpty(text, h.t("Готово.", "Done.")) + "\n\n---\n\n" + h.elapsed(time.Since(started)) + " · " + engineName(engine)
	defer h.warnLimits(chat, thread, engine, warnings)
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

// «Сессия сжата: 720k → 38k»; Telepath shows this line as a service message in the topic
func (h *Helper) compactedText(c Compaction) string {
	k := func(n int) string { return fmt.Sprintf("%dk", (n+500)/1000) }
	text := h.t("Сессия сжата", "Session compacted")
	if c.Before > 0 && c.After > 0 {
		return text + ": " + k(c.Before) + " → " + k(c.After)
	}
	if c.Before > 0 {
		return text + h.t(", было ", ", was ") + k(c.Before)
	}
	return text
}
