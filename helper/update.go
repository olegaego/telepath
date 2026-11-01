package main

import (
	"archive/zip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Updates of the helper: it looks at the project's releases on GitHub itself (at start and every 6 hours), and when a
// newer «helper-vX.Y.Z» is out, offers it in the menu; one click downloads it, puts it in place of this one and
// starts it. Nothing is sent: it only reads the public list of releases.

// set at build time from VERSION: -ldflags "-X main.version=…"
var version = "dev"

const releasesURL = "https://api.github.com/repos/olegaego/telepath/releases?per_page=30"

type helperRelease struct {
	Version string
	Asset   string // the download for this system
}

var latestUpdate = struct {
	sync.Mutex
	release *helperRelease
}{}

// the newer release for this system, if there is one
func availableUpdate() *helperRelease {
	latestUpdate.Lock()
	defer latestUpdate.Unlock()
	return latestUpdate.release
}

func checkUpdate() (*helperRelease, error) {
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Get(releasesURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("GitHub ответил %d", resp.StatusCode)
	}
	var releases []struct {
		Tag        string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&releases); err != nil {
		return nil, err
	}
	want := "Telepath-Helper.dmg"
	if runtime.GOOS == "windows" {
		want = "Telepath-Helper-Windows.zip"
	}
	var best *helperRelease
	for _, r := range releases {
		v, ok := strings.CutPrefix(r.Tag, "helper-v")
		if !ok || r.Draft || r.Prerelease || !newerVersion(v, version) || (best != nil && !newerVersion(v, best.Version)) {
			continue
		}
		for _, a := range r.Assets {
			if a.Name == want {
				best = &helperRelease{Version: v, Asset: a.URL}
			}
		}
	}
	latestUpdate.Lock()
	latestUpdate.release = best
	latestUpdate.Unlock()
	return best, nil
}

// «0.10.1» is newer than «0.9.3»; a build without a version («dev») is never offered one
func newerVersion(a, b string) bool {
	if b == "dev" {
		return false
	}
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < max(len(pa), len(pb)); i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}

// looks for an update now and every 6 hours; found tells the menu, once per version
func watchUpdates(found func(*helperRelease)) {
	told := ""
	for {
		if r, err := checkUpdate(); err != nil {
			log.Println("обновления:", err)
		} else if r != nil && r.Version != told {
			told = r.Version
			found(r)
		}
		time.Sleep(6 * time.Hour)
	}
}

// Downloads the release, puts it in place of this helper and starts it; this one quits
func installUpdate(r *helperRelease) error {
	dir, err := os.MkdirTemp("", "agentgram-update")
	if err != nil {
		return err
	}
	file := filepath.Join(dir, filepath.Base(r.Asset))
	if err := download(r.Asset, file); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		return installWindows(file)
	}
	return installMac(file, dir)
}

func download(url, path string) error {
	resp, err := (&http.Client{Timeout: 10 * time.Minute}).Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("скачивание: %d", resp.StatusCode)
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// the app bundle this helper runs from: …/Agentgram Helper.app
func installMac(dmg, dir string) error {
	app := filepath.Dir(filepath.Dir(filepath.Dir(executablePath())))
	if !strings.HasSuffix(app, ".app") {
		return errors.New("помощник запущен не из приложения")
	}
	mount := filepath.Join(dir, "mnt")
	if out, err := exec.Command("hdiutil", "attach", dmg, "-nobrowse", "-quiet", "-mountpoint", mount).CombinedOutput(); err != nil {
		return fmt.Errorf("не открыл dmg: %s", strings.TrimSpace(string(out)))
	}
	defer exec.Command("hdiutil", "detach", mount, "-quiet").Run()
	fresh := filepath.Join(mount, "Telepath Helper.app")
	staged := app + ".new"
	_ = os.RemoveAll(staged)
	if out, err := exec.Command("ditto", fresh, staged).CombinedOutput(); err != nil {
		return fmt.Errorf("не скопировал: %s", strings.TrimSpace(string(out)))
	}
	old := filepath.Join(dir, "old.app")
	if err := os.Rename(app, old); err != nil {
		return err
	}
	if err := os.Rename(staged, app); err != nil {
		_ = os.Rename(old, app)
		return err
	}
	// the new one starts a moment after this one is gone (only one helper runs at a time)
	_ = exec.Command("/bin/sh", "-c", "sleep 2; open "+shellQuote(app)).Start()
	return nil
}

func installWindows(zipPath string) error {
	exe := executablePath()
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer zr.Close()
	staged := exe + ".new"
	found := false
	for _, f := range zr.File {
		if !strings.EqualFold(filepath.Ext(f.Name), ".exe") {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		out, err := os.Create(staged)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(out, rc)
		rc.Close()
		out.Close()
		if err != nil {
			return err
		}
		found = true
		break
	}
	if !found {
		return errors.New("в архиве нет программы")
	}
	// a running .exe can be renamed but not overwritten
	_ = os.Remove(exe + ".old")
	if err := os.Rename(exe, exe+".old"); err != nil {
		return err
	}
	if err := os.Rename(staged, exe); err != nil {
		_ = os.Rename(exe+".old", exe)
		return err
	}
	return exec.Command("cmd", "/c", "timeout /t 2 /nobreak >nul & start \"\" \""+exe+"\"").Start()
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
