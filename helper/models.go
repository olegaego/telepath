package main

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// The models an engine offers, for «Модель» in Agentgram, with their real names. Claude Code keeps on this computer
// the ids it has offered (~/.claude.json): the newest of each family goes to the list, and the extra options it was
// given (like Fable) with their labels. Codex says its list itself (codex debug models). Which model really runs is
// what the engine reports: Claude Code at the start of every answer, Codex in its session files.

type EngineModel struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Detail string `json:"detail,omitempty"`
}

var familyDetails = map[string]string{
	"fable":  "самая мощная, для самых сложных задач",
	"opus":   "умнее, тратит лимит быстрее",
	"sonnet": "быстрее, лимита хватает дольше",
	"haiku":  "самая быстрая, для простого",
}

var claudeID = regexp.MustCompile(`claude-(fable|opus|sonnet|haiku)-(\d+)(?:-(\d{1,2}))?(\[1m\])?"`)

func claudeModels() []EngineModel {
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".claude.json"))
	if err != nil {
		return nil
	}
	type version struct{ major, minor int }
	newest := map[string]version{}
	long := map[string]bool{} // versions offered with the 1M context: chosen with it, so the context stays as it was
	for _, m := range claudeID.FindAllStringSubmatch(string(data), -1) {
		major, _ := strconv.Atoi(m[2])
		minor, _ := strconv.Atoi(m[3])
		if m[4] != "" {
			long[m[1]+strconv.Itoa(major)+"."+strconv.Itoa(minor)] = true
		}
		if v, ok := newest[m[1]]; !ok || major > v.major || (major == v.major && minor > v.minor) {
			newest[m[1]] = version{major, minor}
		}
	}
	list := []EngineModel{}
	for _, family := range []string{"fable", "opus", "sonnet", "haiku"} {
		v, ok := newest[family]
		if !ok {
			continue
		}
		id := "claude-" + family + "-" + strconv.Itoa(v.major)
		name := strings.ToUpper(family[:1]) + family[1:] + " " + strconv.Itoa(v.major)
		if v.minor > 0 {
			id += "-" + strconv.Itoa(v.minor)
			name += "." + strconv.Itoa(v.minor)
		}
		if long[family+strconv.Itoa(v.major)+"."+strconv.Itoa(v.minor)] {
			id += "[1m]"
		}
		list = append(list, EngineModel{ID: id, Name: name, Detail: familyDetails[family]})
	}
	return list
}

var codexModelsCache = struct {
	sync.Mutex
	list []EngineModel
}{}

func codexModels() []EngineModel {
	codexModelsCache.Lock()
	defer codexModelsCache.Unlock()
	if codexModelsCache.list != nil {
		return codexModelsCache.list
	}
	list := []EngineModel{}
	out, err := exec.Command(codexBinary(), "debug", "models").Output()
	if err == nil {
		var res struct {
			Models []struct {
				Slug        string `json:"slug"`
				DisplayName string `json:"display_name"`
				Description string `json:"description"`
				Visibility  string `json:"visibility"`
				Priority    int    `json:"priority"`
			} `json:"models"`
		}
		if json.Unmarshal(out, &res) == nil {
			sort.SliceStable(res.Models, func(i, j int) bool { return res.Models[i].Priority < res.Models[j].Priority })
			for _, m := range res.Models {
				if m.Visibility == "list" {
					list = append(list, EngineModel{ID: m.Slug, Name: firstNonEmpty(m.DisplayName, m.Slug), Detail: m.Description})
				}
			}
		}
	}
	codexModelsCache.list = list
	return list
}

func engineModels(engine string) []EngineModel {
	if engine == "codex" {
		return codexModels()
	}
	if engine == "chat" {
		return []EngineModel{{ID: chatDefaultModel, Name: "Qwen 3.8 Flash", Detail: "без доступа к компьютеру"}}
	}
	return claudeModels()
}

// The model each engine last reported it runs on
var seenModels = struct {
	sync.Mutex
	m map[string]string
}{m: map[string]string{}}

func seenModel(engine, model string) {
	seenModels.Lock()
	seenModels.m[engine] = model
	seenModels.Unlock()
}

// Both engines write the model into every session: the newest session file says what they run on. Claude Code keeps
// them in ~/.claude/projects, Codex in ~/.codex/sessions
func sessionModel(engine string) string {
	home, _ := os.UserHomeDir()
	var files []string
	if engine == "codex" {
		files, _ = filepath.Glob(filepath.Join(home, ".codex", "sessions", "*", "*", "*", "*.jsonl"))
	} else {
		files, _ = filepath.Glob(filepath.Join(home, ".claude", "projects", "*", "*.jsonl"))
	}
	var newest string
	var newestTime int64
	for _, f := range files {
		if st, err := os.Stat(f); err == nil && st.ModTime().UnixNano() > newestTime {
			newest, newestTime = f, st.ModTime().UnixNano()
		}
	}
	if newest == "" {
		return ""
	}
	fh, err := os.Open(newest)
	if err != nil {
		return ""
	}
	defer fh.Close()
	// the end of the file is enough: the model of the last answer
	if st, err := fh.Stat(); err == nil && st.Size() > 1<<20 {
		_, _ = fh.Seek(st.Size()-1<<20, 0)
	}
	model := ""
	re := regexp.MustCompile(`"model":"((?:claude|gpt)[^"]+)"`)
	sc := bufio.NewScanner(fh)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		if m := re.FindSubmatch(sc.Bytes()); m != nil {
			model = string(m[1])
		}
	}
	return model
}

// The model of the engine as one of its list: the chosen one, or the one it reported running on
func currentModel(cfg Config, engine string) string {
	model := cfg.Models[engine]
	if model == "" {
		seenModels.Lock()
		model = seenModels.m[engine]
		seenModels.Unlock()
	}
	if model == "" {
		model = sessionModel(engine)
	}
	plain := strings.TrimSuffix(model, "[1m]")
	for _, m := range engineModels(engine) {
		id := strings.TrimSuffix(m.ID, "[1m]")
		if m.ID == model || id == plain || strings.HasPrefix(plain, id+"-") {
			return m.ID
		}
	}
	return model
}
