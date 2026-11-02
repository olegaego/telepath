package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A computer as the phone sees it: a fresh home, a stand-in Bot API (a token «N:x» is the bot «botN», anything else
// is refused) and the helper's handlers, asked with requests sealed the way Agentgram seals them.
type phoneTest struct {
	t   *testing.T
	n   *Network
	mux *http.ServeMux
}

func newPhoneTest(t *testing.T) *phoneTest {
	t.Setenv("HOME", t.TempDir())
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(strings.Split(r.URL.Path, "/")[1], "bot")
		id, _, ok := strings.Cut(token, ":")
		if !ok || id == "" {
			w.WriteHeader(404)
			_, _ = w.Write([]byte(`{"ok":false,"error_code":404,"description":"Not Found"}`))
			return
		}
		_, _ = w.Write([]byte(`{"ok":true,"result":{"id":` + id + `,"username":"bot` + id + `"}}`))
	}))
	t.Cleanup(api.Close)
	old := botAPI
	botAPI = api.URL
	t.Cleanup(func() { botAPI = old })
	key, _ := ecdh.P256().GenerateKey(rand.Reader)
	n := &Network{key: key, Paired: make(chan Config, 1), AgentsChanged: make(chan struct{}, 8)}
	mux := http.NewServeMux()
	for path, h := range map[string]http.HandlerFunc{"/pair": n.handlePair, "/info": n.handleInfo, "/unpair": n.handleUnpair, "/agent/add": n.handleAddAgent, "/model": n.handleModel, "/access": n.handleAccess, "/engine": n.handleEngine} {
		mux.HandleFunc(path, h)
	}
	return &phoneTest{t: t, n: n, mux: mux}
}

// ECIES on P-256 as the app does it: ephemeral key, HKDF-SHA256 «agentgram pairing», AES-256-GCM
func (p *phoneTest) seal(v any) string {
	plain, _ := json.Marshal(v)
	eph, _ := ecdh.P256().GenerateKey(rand.Reader)
	shared, _ := eph.ECDH(p.n.key.PublicKey())
	k, _ := hkdf.Key(sha256.New, shared, nil, "agentgram pairing", 32)
	block, _ := aes.NewCipher(k)
	gcm, _ := cipher.NewGCM(block)
	nonce := make([]byte, 12)
	_, _ = rand.Read(nonce)
	sealed := append(append(eph.PublicKey().Bytes(), nonce...), gcm.Seal(nil, nonce, plain, nil)...)
	return base64.RawURLEncoding.EncodeToString(sealed)
}

func (p *phoneTest) ask(path string, req map[string]any) (int, map[string]any) {
	r := httptest.NewRequest("POST", path, strings.NewReader(p.seal(req)))
	w := httptest.NewRecorder()
	p.mux.ServeHTTP(w, r)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

// a request of the phone that connected the computer, about one bot
func (p *phoneTest) askAs(path, bot string, extra map[string]any) (int, map[string]any) {
	req := map[string]any{"secret": "phone-secret", "time": time.Now().Unix(), "bot": bot}
	for k, v := range extra {
		req[k] = v
	}
	return p.ask(path, req)
}

func TestPhoneConnectsAndManagesAgents(t *testing.T) {
	p := newPhoneTest(t)
	if code, out := p.ask("/pair", map[string]any{"bot_token": "111:x", "owner_id": 42, "engine": "claude", "secret": "phone-secret"}); code != 200 || out["bot"] != "bot111" {
		t.Fatalf("pair: %d %v", code, out)
	}
	if code, _ := p.ask("/pair", map[string]any{"bot_token": "333:x", "owner_id": 42, "secret": "other"}); code != http.StatusConflict {
		t.Fatalf("a connected computer must not be paired again: %d", code)
	}
	if _, out := p.askAs("/agent/add", "bot111", map[string]any{"token": "222:x", "engine": "codex"}); out["ok"] != true || out["bot"] != "bot222" {
		t.Fatalf("add agent: %v", out)
	}
	if _, out := p.askAs("/agent/add", "bot111", map[string]any{"token": "222:x"}); out["ok"] != false || !strings.Contains(out["error"].(string), "уже работает") {
		t.Fatalf("the same bot twice must be refused with words: %v", out)
	}
	if _, out := p.askAs("/agent/add", "bot111", map[string]any{"token": "nonsense"}); out["ok"] != false || !strings.Contains(out["error"].(string), "Telegram не принял токен") {
		t.Fatalf("a wrong token must say so: %v", out)
	}
	// someone else's phone (another secret) gets nothing
	if code, _ := p.ask("/info", map[string]any{"secret": "stranger", "time": time.Now().Unix()}); code != http.StatusForbidden {
		t.Fatalf("a stranger must be refused: %d", code)
	}
	// each agent its own model and people
	p.askAs("/model", "bot222", map[string]any{"engine": "codex", "model": "gpt-test"})
	p.askAs("/access", "bot111", map[string]any{"add": map[string]any{"id": 7, "name": "Мария"}})
	cfg, _ := loadConfig()
	a1, _ := cfg.agent("bot111")
	a2, _ := cfg.agent("bot222")
	if a2.Engine != "codex" || a2.Models["codex"] != "gpt-test" || a1.Models["codex"] != "" {
		t.Fatalf("models: %v / %v", a1.Models, a2.Models)
	}
	if len(a1.Allowed) != 1 || a1.Allowed[0].ID != 7 || len(a2.Allowed) != 0 {
		t.Fatalf("access: %v / %v", a1.Allowed, a2.Allowed)
	}
	if _, out := p.askAs("/info", "bot222", nil); out["engine"] != "codex" || len(out["agents"].([]any)) != 2 {
		t.Fatalf("info: %v", out)
	}
	// «Отключить» forgets one agent; the last one takes the phone with it
	p.askAs("/unpair", "bot111", nil)
	if cfg, _ = loadConfig(); len(cfg.Agents) != 1 || cfg.PhoneSecret == "" {
		t.Fatalf("after one: %d agents, secret %q", len(cfg.Agents), cfg.PhoneSecret)
	}
	p.askAs("/unpair", "bot222", nil)
	if cfg, _ = loadConfig(); len(cfg.Agents) != 0 || cfg.PhoneSecret != "" {
		t.Fatalf("after the last: %d agents, secret %q", len(cfg.Agents), cfg.PhoneSecret)
	}
}

func TestOldConfigBecomesFirstAgent(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	_ = os.MkdirAll(dataDir(), 0o700)
	old := `{"bot_token":"111:x","owner_id":42,"engine":"codex","bot_name":"axyzrobot","phone_secret":"s","projects_dir":"/p"}`
	_ = os.WriteFile(filepath.Join(dataDir(), "helper.json"), []byte(old), 0o600)
	_ = os.WriteFile(filepath.Join(dataDir(), "state.json"), []byte(`{"offset":5,"topics":{}}`), 0o600)
	cfg, _ := loadConfig()
	if len(cfg.Agents) != 1 || cfg.Agents[0].BotName != "axyzrobot" || cfg.Agents[0].Engine != "codex" || cfg.Agents[0].OwnerID != 42 {
		t.Fatalf("agents: %+v", cfg.Agents)
	}
	if s := loadState("axyzrobot"); s.Offset != 5 {
		t.Fatalf("the first agent takes over state.json: offset %d", s.Offset)
	}
}

func TestAgentFolderAndPeople(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := Config{ProjectsDir: "/projects", Agents: []AgentConfig{{BotName: "a", OwnerID: 42, Allowed: []Person{{ID: 7}}}, {BotName: "b", OwnerID: 42}}}
	cfg.setAgentFolder("a", "/elsewhere")
	if v, _ := cfg.agent("a"); v.ProjectsDir != "/elsewhere" {
		t.Fatalf("a: %s", v.ProjectsDir)
	}
	if v, _ := cfg.agent("b"); v.ProjectsDir != "/projects" {
		t.Fatalf("b keeps the computer's folder: %s", v.ProjectsDir)
	}
	view, _ := cfg.agent("a")
	h := &Helper{cfg: view}
	for id, want := range map[int64]bool{42: true, 7: true, 8: false} {
		if got := h.isOwner(&User{ID: id}); got != want {
			t.Fatalf("user %d: %v", id, got)
		}
	}
	if (&Helper{cfg: view}).isOwner(nil) {
		t.Fatal("no sender is nobody")
	}
}

func TestNewerVersion(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{{"0.2.1", "0.2.0", true}, {"0.10.0", "0.9.9", true}, {"0.2.0", "0.2.0", false}, {"0.1.9", "0.2.0", false}, {"1.0", "0.9.9", true}, {"9.9.9", "dev", false}} {
		if got := newerVersion(c.a, c.b); got != c.want {
			t.Fatalf("%s > %s: %v", c.a, c.b, got)
		}
	}
}

// Agents with no phone (added on the computer, or the phone was disconnected): a phone connects and joins them
func TestPhoneJoinsAgentsWithNoPhone(t *testing.T) {
	p := newPhoneTest(t)
	cfg, _ := loadConfig()
	cfg.putAgent(Config{BotToken: "111:x", OwnerID: 42, BotName: "bot111", Engine: "claude"})
	_ = saveConfig(cfg)
	if code, out := p.ask("/pair", map[string]any{"bot_token": "111:x", "owner_id": 42, "engine": "claude", "secret": "phone-secret"}); code != 200 || out["bot"] != "bot111" {
		t.Fatalf("pair: %d %v", code, out)
	}
	cfg, _ = loadConfig()
	if len(cfg.Agents) != 1 || cfg.PhoneSecret != "phone-secret" {
		t.Fatalf("agents %+v, secret %q", cfg.Agents, cfg.PhoneSecret)
	}
}
