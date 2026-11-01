package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Voice messages to the bot, the owner's own and forwarded ones, become text here on the computer: Whisper on this
// Mac (whisper.cpp, a model downloaded once into ~/.agentgram/models) or Groq with the owner's key. The voice comes
// from Telegram itself, so it works at home and away, and nothing is attached to the message.

type whisperModel struct {
	ID        string
	File      string
	Megabytes int
}

var whisperModels = []whisperModel{
	{ID: "light", File: "ggml-base.bin", Megabytes: 148},
	{ID: "accurate", File: "ggml-large-v3-turbo-q5_0.bin", Megabytes: 574},
}

func modelByID(id string) whisperModel {
	for _, m := range whisperModels {
		if m.ID == id {
			return m
		}
	}
	return whisperModels[0]
}

func modelsDir() string {
	return filepath.Join(dataDir(), "models")
}

func (m whisperModel) path() string {
	return filepath.Join(modelsDir(), m.File)
}

func (m whisperModel) downloaded() bool {
	st, err := os.Stat(m.path())
	return err == nil && st.Size() > 1<<20
}

// Downloads of the models, with how far they got
var modelDownloads = struct {
	sync.Mutex
	progress map[string]float64
}{progress: map[string]float64{}}

func downloadModel(m whisperModel) {
	modelDownloads.Lock()
	if _, going := modelDownloads.progress[m.ID]; going || m.downloaded() {
		modelDownloads.Unlock()
		return
	}
	modelDownloads.progress[m.ID] = 0
	modelDownloads.Unlock()
	go func() {
		defer func() {
			modelDownloads.Lock()
			delete(modelDownloads.progress, m.ID)
			modelDownloads.Unlock()
		}()
		_ = os.MkdirAll(modelsDir(), 0o700)
		resp, err := http.Get("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + m.File)
		if err != nil || resp.StatusCode != 200 {
			if resp != nil {
				resp.Body.Close()
			}
			return
		}
		defer resp.Body.Close()
		tmp := m.path() + ".part"
		f, err := os.Create(tmp)
		if err != nil {
			return
		}
		total := float64(resp.ContentLength)
		var done float64
		buf := make([]byte, 1<<20)
		for {
			n, err := resp.Body.Read(buf)
			if n > 0 {
				if _, werr := f.Write(buf[:n]); werr != nil {
					f.Close()
					return
				}
				done += float64(n)
				if total > 0 {
					modelDownloads.Lock()
					modelDownloads.progress[m.ID] = done / total
					modelDownloads.Unlock()
				}
			}
			if err == io.EOF {
				break
			}
			if err != nil {
				f.Close()
				return
			}
		}
		f.Close()
		_ = os.Rename(tmp, m.path())
	}()
}

// The state of voice recognition, for Agentgram's «Распознавание»
func voiceStatus(cfg Config) map[string]any {
	models := map[string]any{}
	modelDownloads.Lock()
	for _, m := range whisperModels {
		state := map[string]any{"downloaded": m.downloaded(), "megabytes": m.Megabytes}
		if p, ok := modelDownloads.progress[m.ID]; ok {
			state["progress"] = p
		}
		models[m.ID] = state
	}
	modelDownloads.Unlock()
	return map[string]any{"mode": firstNonEmpty(cfg.Voice, "off"), "model": firstNonEmpty(cfg.VoiceModel, "light"), "groq_model": firstNonEmpty(cfg.GroqModel, "whisper-large-v3-turbo"), "groq_key": cfg.GroqKey != "", "models": models, "whisper_here": whisperBinary() != ""}
}

// whisper-cli: inside Agentgram Helper.app, next to the helper, or on PATH
func whisperBinary() string {
	exe := executablePath()
	for _, p := range []string{filepath.Join(filepath.Dir(exe), "..", "Resources", "whisper-cli"), filepath.Join(filepath.Dir(exe), "whisper-cli"), filepath.Join(filepath.Dir(exe), "whisper", "whisper-cli")} {
		if fileExists(p) {
			return p
		}
	}
	if p, err := exec.LookPath("whisper-cli"); err == nil {
		return p
	}
	return ""
}

var errVoiceOff = errors.New("voice off")

// A voice message's text, by the way the owner chose
func (h *Helper) transcribe(fileID string) (string, error) {
	h.mu.Lock()
	cfg := h.cfg
	h.mu.Unlock()
	mode := firstNonEmpty(cfg.Voice, "off")
	if mode == "off" {
		return "", errVoiceOff
	}
	data, _, err := h.bot.Download(fileID)
	if err != nil {
		return "", fmt.Errorf("не скачал голосовое: %w", err)
	}
	language := "ru"
	if mode == "groq" {
		if cfg.GroqKey == "" {
			return "", errors.New("нет ключа Groq: вставь его в Telepath, Настройки → Telepath → Распознавание")
		}
		return groqTranscribe(data, cfg.GroqKey, firstNonEmpty(cfg.GroqModel, "whisper-large-v3-turbo"), language)
	}
	model := modelByID(cfg.VoiceModel)
	if !model.downloaded() {
		downloadModel(model)
		return "", errors.New("модель Whisper ещё скачивается на компьютер, попробуй через минуту")
	}
	bin := whisperBinary()
	if bin == "" {
		return "", errors.New("на этом компьютере нет Whisper")
	}
	dir, err := os.MkdirTemp("", "agentgram-voice")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	in, wav := filepath.Join(dir, "voice.ogg"), filepath.Join(dir, "voice.wav")
	if err := os.WriteFile(in, data, 0o600); err != nil {
		return "", err
	}
	// the Mac opens Telegram's Opus itself; Whisper wants 16 kHz mono
	if out, err := exec.Command("afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", in, wav).CombinedOutput(); err != nil {
		return "", fmt.Errorf("не открыл голосовое: %s", strings.TrimSpace(string(out)))
	}
	cmd := exec.Command(bin, "-m", model.path(), "-f", wav, "-l", language, "-nt", "-np")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("Whisper не справился: %v", err)
	}
	return strings.TrimSpace(strings.Join(strings.Fields(string(out)), " ")), nil
}

func groqTranscribe(audio []byte, key, model, language string) (string, error) {
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	_ = w.WriteField("model", model)
	_ = w.WriteField("language", language)
	_ = w.WriteField("response_format", "json")
	part, _ := w.CreateFormFile("file", "voice.ogg")
	_, _ = part.Write(audio)
	_ = w.Close()
	req, _ := http.NewRequest("POST", "https://api.groq.com/openai/v1/audio/transcriptions", &body)
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", w.FormDataContentType())
	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		// Go's TLS gets «bad record MAC» from Groq on bodies over ~10 KB, while the system curl gets through
		if text, cerr := groqTranscribeCurl(audio, key, model, language); cerr == nil {
			return text, nil
		}
		return "", fmt.Errorf("Groq не ответил: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 {
		return "", errors.New("Groq не принял ключ")
	}
	var res struct {
		Text string `json:"text"`
	}
	if resp.StatusCode != 200 || json.NewDecoder(resp.Body).Decode(&res) != nil {
		return "", fmt.Errorf("Groq ответил %d", resp.StatusCode)
	}
	return strings.TrimSpace(res.Text), nil
}

func groqTranscribeCurl(audio []byte, key, model, language string) (string, error) {
	curl, err := exec.LookPath("curl")
	if err != nil {
		return "", err
	}
	dir, err := os.MkdirTemp("", "agentgram-groq")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	voice, header := filepath.Join(dir, "voice.ogg"), filepath.Join(dir, "header")
	// the key goes in a file, not on the command line, where other programs could read it
	if os.WriteFile(voice, audio, 0o600) != nil || os.WriteFile(header, []byte("Authorization: Bearer "+key+"\n"), 0o600) != nil {
		return "", errors.New("не записал голосовое")
	}
	out, err := exec.Command(curl, "-sS", "--max-time", "60", "-w", "\n%{http_code}", "-H", "@"+header, "-F", "model="+model, "-F", "language="+language, "-F", "response_format=json", "-F", "file=@"+voice, "https://api.groq.com/openai/v1/audio/transcriptions").Output()
	if err != nil {
		return "", err
	}
	// -w puts the status on the last line
	trimmed := strings.TrimSpace(string(out))
	i := strings.LastIndex(trimmed, "\n")
	body, code := trimmed[:max(i, 0)], trimmed[i+1:]
	if code == "401" {
		return "", errors.New("Groq не принял ключ")
	}
	var res struct {
		Text string `json:"text"`
	}
	if code != "200" || json.Unmarshal([]byte(body), &res) != nil {
		return "", fmt.Errorf("Groq ответил %s", code)
	}
	return strings.TrimSpace(res.Text), nil
}
