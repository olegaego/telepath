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
	key      *ecdh.PrivateKey
	port     int
	server   *http.Server
	announce *zeroconf.Server
	Paired   chan Config
	Unpaired chan struct{}
	Status   func() map[string]any // what /info tells about the work: topics, running turns
	OnEngine func(engine string)   // the phone switched the engine
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
	n := &Network{key: key, port: listener.Addr().(*net.TCPAddr).Port, Paired: make(chan Config, 1), Unpaired: make(chan struct{}, 1)}
	mux := http.NewServeMux()
	mux.HandleFunc("/pair", n.handlePair)
	mux.HandleFunc("/info", n.handleInfo)
	mux.HandleFunc("/unpair", n.handleUnpair)
	mux.HandleFunc("/engine", n.handleEngine)
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
	if n.announce != nil {
		n.announce.Shutdown()
	}
	txt := []string{"v=1", "pk=" + base64.RawURLEncoding.EncodeToString(n.key.PublicKey().Bytes())}
	if cfg.BotToken != "" {
		txt = append(txt, "paired=1", "bot="+cfg.BotName, "engine="+cfg.Engine)
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
	if cfg, _ := loadConfig(); cfg.BotToken != "" {
		// already connected: connecting again only after «Disconnect» in Agentgram, or «agentgram-helper pair» here
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
	cfg.BotToken, cfg.OwnerID, cfg.BotName, cfg.PhoneSecret = p.BotToken, p.OwnerID, me.Username, p.Secret
	if p.Engine != "" {
		cfg.Engine = p.Engine
	}
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
	}
	cfg, _ := loadConfig()
	if json.Unmarshal(plain, &req) != nil || cfg.PhoneSecret == "" || req.Secret != cfg.PhoneSecret || abs(time.Now().Unix()-req.Time) > 300 {
		http.Error(w, "not yours", http.StatusForbidden)
		return Config{}, nil, false
	}
	return cfg, plain, true
}

// The phone switches the engine: the same as in the menu here
func (n *Network) handleEngine(w http.ResponseWriter, r *http.Request) {
	_, plain, ok := n.authorizedRequest(w, r)
	if !ok {
		return
	}
	var req struct {
		Engine string `json:"engine"`
	}
	if json.Unmarshal(plain, &req) != nil || (req.Engine != "claude" && req.Engine != "codex") || !engineInstalled(req.Engine) {
		http.Error(w, "bad engine", http.StatusBadRequest)
		return
	}
	if n.OnEngine != nil {
		n.OnEngine(req.Engine)
	}
	writeJSON(w, map[string]any{"ok": true, "engine": req.Engine})
}

func (n *Network) handleInfo(w http.ResponseWriter, r *http.Request) {
	cfg, ok := n.authorized(w, r)
	if !ok {
		return
	}
	info := map[string]any{"bot": cfg.BotName, "engine": cfg.Engine, "projects": cfg.ProjectsDir, "computer": computerName(),
		"limits": knownLimits(), "installed": map[string]bool{"claude": engineInstalled("claude"), "codex": engineInstalled("codex")}}
	if n.Status != nil {
		for k, v := range n.Status() {
			info[k] = v
		}
	}
	writeJSON(w, info)
}

func (n *Network) handleUnpair(w http.ResponseWriter, r *http.Request) {
	if _, ok := n.authorized(w, r); !ok {
		return
	}
	if err := n.Unpair(); err != nil {
		http.Error(w, "save", http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

// Forgets the bot and its token (from the phone or from the menu here) and waits for a phone again
func (n *Network) Unpair() error {
	cfg, _ := loadConfig()
	cfg.BotToken, cfg.OwnerID, cfg.BotName, cfg.PhoneSecret = "", 0, "", ""
	if err := saveConfig(cfg); err != nil {
		return err
	}
	n.reannounce(cfg)
	select {
	case n.Unpaired <- struct{}{}:
	default:
	}
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
