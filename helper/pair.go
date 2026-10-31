package main

import (
	"context"
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

// Waits on the network until Agentgram connects, then saves the settings and returns them
func pair() (Config, error) {
	key, err := deviceKey()
	if err != nil {
		return Config{}, err
	}
	pub := key.PublicKey().Bytes()
	code := pairingCode(pub)
	listener, err := net.Listen("tcp", ":0")
	if err != nil {
		return Config{}, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	done := make(chan Config, 1)
	mux := http.NewServeMux()
	mux.HandleFunc("/pair", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "", http.StatusMethodNotAllowed)
			return
		}
		body, _ := io.ReadAll(io.LimitReader(r.Body, 8192))
		sealed, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(string(body)))
		if err != nil {
			http.Error(w, "bad", http.StatusBadRequest)
			return
		}
		plain, err := openPairing(key, sealed)
		if err != nil {
			http.Error(w, "bad", http.StatusBadRequest)
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
		cfg.BotToken, cfg.OwnerID = p.BotToken, p.OwnerID
		if p.Engine != "" {
			cfg.Engine = p.Engine
		}
		if err := saveConfig(cfg); err != nil {
			http.Error(w, "save", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "bot": me.Username, "computer": computerName()})
		select {
		case done <- cfg:
		default:
		}
	})
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = server.Serve(listener) }()
	// announced with the plain host name and the computer's own addresses (Register would add «.local» twice on a Mac)
	announce, err := zeroconf.RegisterProxy(computerName(), pairService, "local.", port, computerName(), localAddresses(), []string{"v=1", "pk=" + base64.RawURLEncoding.EncodeToString(pub)}, nil)
	if err != nil {
		_ = server.Close()
		return Config{}, err
	}
	fmt.Println()
	fmt.Println("Жду Agentgram в этой сети.")
	fmt.Println("В Agentgram: Настройки → Agentgram → Компьютеры → «" + computerName() + "» → Подключить.")
	fmt.Println("Код на телефоне должен быть таким:  " + code[:3] + " " + code[3:])
	fmt.Println()
	cfg := <-done
	announce.Shutdown()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = server.Shutdown(ctx)
	log.Println("подключён")
	return cfg, nil
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
