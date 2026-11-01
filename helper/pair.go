package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/grandcat/zeroconf"
)

// Connecting to Agentgram, on the same network only. The helper announces itself (Bonjour, _agentgram._tcp) with its
// public key; Agentgram shows the computer, both show the same 6-digit code made from that key, and after the owner
// confirms, the phone sends the bot's token sealed with the key straight to the helper. Nothing goes through any server,
// and a fake helper on the same Wi-Fi would show a different code.

const pairService = "_agentgram._tcp"

func deviceKey() (*ecdh.PrivateKey, error) {
	path := filepath.Join(dataDir(), "device.key")
	if data, err := os.ReadFile(path); err == nil {
		return ecdh.P256().NewPrivateKey(data)
	}
	key, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dataDir(), 0o700); err != nil {
		return nil, err
	}
	return key, writeFileAtomic(path, key.Bytes(), 0o600)
}

// The code both screens show: from the key itself, so it cannot be copied without the key
func pairingCode(pub []byte) string {
	sum := sha256.Sum256(append([]byte("agentgram pairing code"), pub...))
	return fmt.Sprintf("%06d", binary.BigEndian.Uint32(sum[:4])%1_000_000)
}

type pairPayload struct {
	BotToken string `json:"bot_token"`
	OwnerID  int64  `json:"owner_id"`
	Engine   string `json:"engine"`
	Secret   string `json:"secret"` // the phone's own secret, to ask this computer later (info, disconnect)
}

// ECIES on P-256, as the app does it: the phone's ephemeral key (65) + AES-256-GCM (nonce 12, ciphertext, tag 16),
// the key from HKDF-SHA256 of the shared secret
func openPairing(key *ecdh.PrivateKey, sealed []byte) ([]byte, error) {
	if len(sealed) < 65+12+16 {
		return nil, errors.New("short")
	}
	peer, err := ecdh.P256().NewPublicKey(sealed[:65])
	if err != nil {
		return nil, err
	}
	shared, err := key.ECDH(peer)
	if err != nil {
		return nil, err
	}
	aesKey, err := hkdf.Key(sha256.New, shared, nil, "agentgram pairing", 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return gcm.Open(nil, sealed[65:77], sealed[77:], nil)
}

func computerName() string {
	name, _ := os.Hostname()
	name = strings.TrimSuffix(strings.TrimSuffix(name, ".local"), ".lan")
	if name == "" {
		name = "Computer"
	}
	return name
}

// The helper on the local network, all the time it runs: announced (Bonjour) with its key, whether it is connected
// and to which bot; /pair while it is not connected, and for the phone that connected it /info and /unpair. Those two
// carry the secret that phone sent when connecting, sealed with the computer's key, so nobody else on the network can ask.
type Network struct {
	key           *ecdh.PrivateKey
	port          int
	server        *http.Server
	announce      *zeroconf.Server
	Paired        chan Config
	AgentsChanged chan struct{}                   // an agent was added or removed
	Status        func(bot string) map[string]any // what /info tells about an agent's work: topics, running turns
	OnEngine      func(bot, engine string)        // the phone switched an agent's engine
	OnStatuses    func(mode string)               // the phone chose how statuses reach it
	OnSettings    func(cfg Config)                // the phone changed voice recognition, a model or the people let in
	Topics        func() []TopicStatus            // what each topic of each agent does now, for /status
	OnStop        func(bot string, chat, thread int64)
}

func startNetwork(cfg Config) (*Network, error) {
	key, err := deviceKey()
	if err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp", ":0")
	if err != nil {
		return nil, err
	}
	n := &Network{key: key, port: listener.Addr().(*net.TCPAddr).Port, Paired: make(chan Config, 1), AgentsChanged: make(chan struct{}, 1)}
	mux := http.NewServeMux()
	mux.HandleFunc("/pair", n.handlePair)
	mux.HandleFunc("/info", n.handleInfo)
	mux.HandleFunc("/unpair", n.handleUnpair)
	mux.HandleFunc("/agent/add", n.handleAddAgent)
	mux.HandleFunc("/engine", n.handleEngine)
	mux.HandleFunc("/statuses", n.handleStatuses)
	mux.HandleFunc("/voice", n.handleVoice)
	mux.HandleFunc("/model", n.handleModel)
	mux.HandleFunc("/access", n.handleAccess)
	mux.HandleFunc("/status", n.handleStatus)
	mux.HandleFunc("/stop", n.handleStop)
	n.server = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = n.server.Serve(listener) }()
	n.reannounce(cfg)
	return n, nil
}

// Leaves the network: the announcement is withdrawn (a «goodbye» the phones see right away) and the server stops
func (n *Network) Shutdown() {
	if n.announce != nil {
		n.announce.Shutdown()
	}
	_ = n.server.Close()
}

func (n *Network) Code() string {
	code := pairingCode(n.key.PublicKey().Bytes())
	return code[:3] + " " + code[3:]
}

// announced with the plain host name and the computer's own addresses (Register would add «.local» twice on a Mac)
func (n *Network) reannounce(cfg Config) {
	// not listening (a test talking to the handlers directly): nothing to announce
	if n.port == 0 {
		return
	}
	if n.announce != nil {
		n.announce.Shutdown()
	}
	txt := []string{"v=1", "pk=" + base64.RawURLEncoding.EncodeToString(n.key.PublicKey().Bytes())}
	if len(cfg.Agents) > 0 {
		bots := []string{}
		for _, a := range cfg.Agents {
			bots = append(bots, a.BotName)
		}
		txt = append(txt, "paired=1", "bot="+cfg.BotName, "engine="+cfg.Engine, "bots="+strings.Join(bots, ","))
	}
	announce, err := zeroconf.RegisterProxy(computerName(), pairService, "local.", n.port, computerName(), localAddresses(), txt, nil)
	if err != nil {
		log.Println("сеть:", err)
		return
	}
	n.announce = announce
}

func (n *Network) readSealed(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	if r.Method != http.MethodPost {
		http.Error(w, "", http.StatusMethodNotAllowed)
		return nil, false
	}
	body, _ := io.ReadAll(io.LimitReader(r.Body, 8192))
	sealed, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(string(body)))
	if err != nil {
		http.Error(w, "bad", http.StatusBadRequest)
		return nil, false
	}
	plain, err := openPairing(n.key, sealed)
	if err != nil {
		http.Error(w, "bad", http.StatusBadRequest)
		return nil, false
	}
	return plain, true
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func (n *Network) handlePair(w http.ResponseWriter, r *http.Request) {
	if cfg, _ := loadConfig(); len(cfg.Agents) > 0 {
		// already connected: more agents come through /agent/add from the phone that connected it
		http.Error(w, "already connected", http.StatusConflict)
		return
	}
	plain, ok := n.readSealed(w, r)
	if !ok {
		return
	}
	var p pairPayload
	if json.Unmarshal(plain, &p) != nil || p.BotToken == "" || p.OwnerID == 0 {
		http.Error(w, "bad", http.StatusBadRequest)
		return
	}
	me, err := NewBot(p.BotToken).GetMe()
	if err != nil {
		http.Error(w, "the bot does not answer", http.StatusBadRequest)
		return
	}
	cfg, _ := loadConfig()
	cfg.PhoneSecret = p.Secret
	cfg.putAgent(Config{BotToken: p.BotToken, OwnerID: p.OwnerID, BotName: me.Username, Engine: firstNonEmpty(p.Engine, "claude")})
	if err := saveConfig(cfg); err != nil {
		http.Error(w, "save", http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"ok": true, "bot": me.Username, "computer": computerName(), "projects": cfg.ProjectsDir})
	n.reannounce(cfg)
	select {
	case n.Paired <- cfg:
	default:
	}
}

// The phone proves it is the one that connected this computer: the secret it sent then, and a fresh time
func (n *Network) authorized(w http.ResponseWriter, r *http.Request) (Config, bool) {
	cfg, _, ok := n.authorizedRequest(w, r)
	return cfg, ok
}

func (n *Network) authorizedRequest(w http.ResponseWriter, r *http.Request) (Config, []byte, bool) {
	plain, ok := n.readSealed(w, r)
	if !ok {
		return Config{}, nil, false
	}
	var req struct {
		Secret string `json:"secret"`
		Time   int64  `json:"time"`
		Bot    string `json:"bot"` // which agent the request is about; empty: the first
	}
	cfg, _ := loadConfig()
	if json.Unmarshal(plain, &req) != nil || cfg.PhoneSecret == "" || req.Secret != cfg.PhoneSecret || abs(time.Now().Unix()-req.Time) > 300 {
		http.Error(w, "not yours", http.StatusForbidden)
		return Config{}, nil, false
	}
	if view, ok := cfg.agent(req.Bot); ok {
		cfg = view
	}
	return cfg, plain, true
}

// The phone on the same Wi-Fi asks every second or two: each topic's state, what it does, its steps
func (n *Network) handleStatus(w http.ResponseWriter, r *http.Request) {
	cfg, ok := n.authorized(w, r)
	if !ok {
		return
	}
	topics := []TopicStatus{}
	if n.Topics != nil {
		topics = n.Topics()
	}
	writeJSON(w, map[string]any{"bot": cfg.BotName, "engine": cfg.Engine, "now": time.Now().Unix(), "topics": topics, "limits": knownLimits()})
}

// «Stop» in the topic's header, when the phone is nearby: the same as /stop in the topic
func (n *Network) handleStop(w http.ResponseWriter, r *http.Request) {
	cfg, plain, ok := n.authorizedRequest(w, r)
	if !ok {
		return
	}
	var req struct {
		Chat   int64 `json:"chat"`
		Thread int64 `json:"thread"`
	}
	if json.Unmarshal(plain, &req) != nil || req.Chat == 0 {
		http.Error(w, "bad", http.StatusBadRequest)
		return
	}
	if n.OnStop != nil {
		n.OnStop(cfg.BotName, req.Chat, req.Thread)
	}
	writeJSON(w, map[string]any{"ok": true})
}

// The phone sets voice recognition: off, Whisper here (which model) or Groq (the key, the model). The key comes sealed
// with the computer's key, over the local network, and stays in ~/.agentgram
func (n *Network) handleVoice(w http.ResponseWriter, r *http.Request) {
	_, plain, ok := n.authorizedRequest(w, r)
	if !ok {
		return
	}
	var req struct {
		Mode      *string `json:"mode"`
		Model     *string `json:"model"`
		GroqKey   *string `json:"groq_key"`
		GroqModel *string `json:"groq_model"`
	}
	if json.Unmarshal(plain, &req) != nil {
		http.Error(w, "bad", http.StatusBadRequest)
		return
	}
	cfg, _ := loadConfig()
	if req.Mode != nil && (*req.Mode == "off" || *req.Mode == "whisper" || *req.Mode == "groq") {
		cfg.Voice = *req.Mode
	}
	if req.Model != nil {
		cfg.VoiceModel = modelByID(*req.Model).ID
	}
	if req.GroqKey != nil {
		cfg.GroqKey = strings.TrimSpace(*req.GroqKey)
	}
	if req.GroqModel != nil && *req.GroqModel != "" {
		cfg.GroqModel = *req.GroqModel
	}
	if !n.save(w, cfg) {
		return
	}
	if cfg.Voice == "whisper" {
		downloadModel(modelByID(cfg.VoiceModel))
	}
	writeJSON(w, map[string]any{"ok": true, "voice": voiceStatus(cfg)})
}

// The phone chooses how statuses reach it: «off», «lan» or «everywhere»
func (n *Network) handleStatuses(w http.ResponseWriter, r *http.Request) {
	_, plain, ok := n.authorizedRequest(w, r)
	if !ok {
		return
	}
	var req struct {
		Mode string `json:"mode"`
	}
	if json.Unmarshal(plain, &req) != nil || (req.Mode != "off" && req.Mode != "lan" && req.Mode != "everywhere") {
		http.Error(w, "bad mode", http.StatusBadRequest)
		return
	}
	if n.OnStatuses != nil {
		n.OnStatuses(req.Mode)
	}
	writeJSON(w, map[string]any{"ok": true, "mode": req.Mode})
}

// The phone switches the engine: the same as in the menu here
func (n *Network) handleEngine(w http.ResponseWriter, r *http.Request) {
	cfg, plain, ok := n.authorizedRequest(w, r)
	if !ok {
		return
	}
	var req struct {
		Engine string `json:"engine"`
	}
	if json.Unmarshal(plain, &req) != nil || (req.Engine != "claude" && req.Engine != "codex" && req.Engine != "chat") || !engineInstalled(req.Engine) {
		http.Error(w, "bad engine", http.StatusBadRequest)
		return
	}
	if n.OnEngine != nil {
		n.OnEngine(cfg.BotName, req.Engine)
	}
	writeJSON(w, map[string]any{"ok": true, "engine": req.Engine})
}

func (n *Network) handleInfo(w http.ResponseWriter, r *http.Request) {
	cfg, ok := n.authorized(w, r)
	if !ok {
		return
	}
	info := map[string]any{"bot": cfg.BotName, "engine": cfg.Engine, "projects": cfg.ProjectsDir, "computer": computerName(), "statuses": firstNonEmpty(cfg.Statuses, "off"), "voice": voiceStatus(cfg),
		"limits": knownLimits(), "model": currentModel(cfg, firstNonEmpty(cfg.Engine, "claude")), "models": engineModels(firstNonEmpty(cfg.Engine, "claude")), "allowed": allowedList(cfg), "installed": map[string]bool{"claude": engineInstalled("claude"), "codex": engineInstalled("codex"), "chat": engineInstalled("chat")}}
	if n.Status != nil {
		for k, v := range n.Status(cfg.BotName) {
			info[k] = v
		}
	}
	all, _ := loadConfig()
	agents := []map[string]any{}
	for _, a := range all.Agents {
		agents = append(agents, map[string]any{"bot": a.BotName, "engine": firstNonEmpty(a.Engine, "claude")})
	}
	info["agents"] = agents
	writeJSON(w, info)
}

// «Отключить» on an agent's screen: this computer forgets that bot; with the last one gone it forgets the phone too
func (n *Network) handleUnpair(w http.ResponseWriter, r *http.Request) {
	cfg, ok := n.authorized(w, r)
	if !ok {
		return
	}
	if err := n.RemoveAgent(cfg.BotName); err != nil {
		http.Error(w, "save", http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

// One more agent on this computer, from the phone that connected it: the bot's token and the engine, sealed. What
// went wrong comes back in words (with 200), for the phone to show
func (n *Network) handleAddAgent(w http.ResponseWriter, r *http.Request) {
	cfg, plain, ok := n.authorizedRequest(w, r)
	if !ok {
		log.Println("новый агент: запрос не от этого телефона")
		return
	}
	fail := func(text string) {
		log.Println("новый агент:", text)
		writeJSON(w, map[string]any{"ok": false, "error": text})
	}
	var req struct {
		Token  string `json:"token"`
		Engine string `json:"engine"`
	}
	if json.Unmarshal(plain, &req) != nil || strings.TrimSpace(req.Token) == "" {
		fail("нет токена")
		return
	}
	token := strings.TrimSpace(req.Token)
	me, err := NewBot(token).GetMe()
	if err != nil {
		fail("Telegram не принял токен: " + err.Error())
		return
	}
	all, _ := loadConfig()
	if _, exists := all.agent(me.Username); exists {
		fail("@" + me.Username + " уже работает на этом компьютере")
		return
	}
	all.putAgent(Config{BotToken: token, BotName: me.Username, OwnerID: cfg.OwnerID, Engine: firstNonEmpty(req.Engine, "claude")})
	if err := saveConfig(all); err != nil {
		fail("не сохранил: " + err.Error())
		return
	}
	all, _ = loadConfig()
	log.Printf("новый агент: @%s, движок %s", me.Username, firstNonEmpty(req.Engine, "claude"))
	n.reannounce(all)
	n.agentsChanged()
	writeJSON(w, map[string]any{"ok": true, "bot": me.Username, "computer": computerName(), "projects": all.ProjectsDir})
}

func (n *Network) agentsChanged() {
	select {
	case n.AgentsChanged <- struct{}{}:
	default:
	}
}

// Forgets one agent's bot and token; with no agent left, the phone too, and waits for a phone again
func (n *Network) RemoveAgent(bot string) error {
	cfg, _ := loadConfig()
	cfg.removeAgent(bot)
	if len(cfg.Agents) == 0 {
		cfg.PhoneSecret = ""
	}
	if err := saveConfig(cfg); err != nil {
		return err
	}
	cfg, _ = loadConfig()
	n.reannounce(cfg)
	n.agentsChanged()
	return nil
}

// Forgets every agent and the phone (from the menu here) and waits for a phone again
func (n *Network) Unpair() error {
	cfg, _ := loadConfig()
	cfg.Agents, cfg.PhoneSecret = nil, ""
	if err := saveConfig(cfg); err != nil {
		return err
	}
	cfg, _ = loadConfig()
	n.reannounce(cfg)
	n.agentsChanged()
	return nil
}

func abs(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

func localAddresses() []string {
	var out []string
	ifaces, _ := net.Interfaces()
	for _, i := range ifaces {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && !n.IP.IsLinkLocalUnicast() {
				out = append(out, n.IP.String())
			}
		}
	}
	return out
}

// The phone picks the engine's model; empty is the engine's own default
func (n *Network) handleModel(w http.ResponseWriter, r *http.Request) {
	cfg, plain, ok := n.authorizedRequest(w, r)
	if !ok {
		return
	}
	var req struct {
		Engine string `json:"engine"`
		Model  string `json:"model"`
	}
	if json.Unmarshal(plain, &req) != nil || (req.Engine != "claude" && req.Engine != "codex" && req.Engine != "chat") {
		http.Error(w, "bad", http.StatusBadRequest)
		return
	}
	all, _ := loadConfig()
	cfg, _ = all.agent(cfg.BotName)
	if cfg.Models == nil {
		cfg.Models = map[string]string{}
	}
	cfg.Models[req.Engine] = req.Model
	all.putAgent(cfg)
	if !n.save(w, all) {
		return
	}
	writeJSON(w, map[string]any{"ok": true, "model": req.Model})
}

// The phone lets someone use the agent, or takes it back
func (n *Network) handleAccess(w http.ResponseWriter, r *http.Request) {
	cfg, plain, ok := n.authorizedRequest(w, r)
	if !ok {
		return
	}
	var req struct {
		Add    *Person `json:"add"`
		Remove int64   `json:"remove"`
	}
	if json.Unmarshal(plain, &req) != nil {
		http.Error(w, "bad", http.StatusBadRequest)
		return
	}
	all, _ := loadConfig()
	kept := cfg.Allowed[:0:0]
	for _, p := range cfg.Allowed {
		if p.ID != req.Remove && (req.Add == nil || p.ID != req.Add.ID) {
			kept = append(kept, p)
		}
	}
	if req.Add != nil && req.Add.ID != 0 && req.Add.ID != cfg.OwnerID {
		kept = append(kept, Person{ID: req.Add.ID, Name: req.Add.Name, Added: time.Now().Unix()})
	}
	cfg.Allowed = kept
	all.putAgent(cfg)
	if !n.save(w, all) {
		return
	}
	writeJSON(w, map[string]any{"ok": true, "allowed": allowedList(cfg)})
}

func allowedList(cfg Config) []Person {
	if cfg.Allowed == nil {
		return []Person{}
	}
	return cfg.Allowed
}

// Saves what the phone changed and lets the agents take it at once; false, with the error sent, when it could not
func (n *Network) save(w http.ResponseWriter, cfg Config) bool {
	if err := saveConfig(cfg); err != nil {
		http.Error(w, "save", http.StatusInternalServerError)
		return false
	}
	if n.OnSettings != nil {
		n.OnSettings(cfg)
	}
	return true
}
