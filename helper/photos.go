package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

// Pictures in an answer: a line [[фото: путь]] (or [[фото: путь 1280x800]]) becomes a photo in the topic, sent before
// the text; an HTML file is taken as a picture by the browser without a window, a PNG or JPG goes as it is. Up to 10,
// several as an album.
var photoLine = regexp.MustCompile(`(?i)\[\[\s*фото\s*:\s*(.+?)(?:\s+(\d{2,4})\s*[x×]\s*(\d{2,4}))?\s*\]\]`)

type photoRef struct {
	Path   string
	Width  int
	Height int
}

// takePhotos cuts the photo lines out of the answer and says what they show, paths relative to the topic's folder
func takePhotos(text, cwd string) (string, []photoRef) {
	var refs []photoRef
	for _, m := range photoLine.FindAllStringSubmatch(text, -1) {
		path := strings.Trim(strings.TrimSpace(m[1]), "`'\"")
		if strings.HasPrefix(path, "~/") {
			path = filepath.Join(homeDir(), path[2:])
		} else if !filepath.IsAbs(path) {
			path = filepath.Join(cwd, path)
		}
		w, h := 390, 844
		if m[2] != "" {
			w, _ = strconv.Atoi(m[2])
			h, _ = strconv.Atoi(m[3])
		}
		if len(refs) < 10 {
			refs = append(refs, photoRef{Path: path, Width: w, Height: h})
		}
	}
	text = photoLine.ReplaceAllString(text, "")
	text = regexp.MustCompile(`\n{3,}`).ReplaceAllString(text, "\n\n")
	return strings.TrimSpace(text), refs
}

// the picture's bytes and file name; HTML is shot at twice its size, like a phone's screen
func renderPhoto(ref photoRef) ([]byte, string, error) {
	lower := strings.ToLower(ref.Path)
	if !strings.HasSuffix(lower, ".html") && !strings.HasSuffix(lower, ".htm") {
		data, err := os.ReadFile(ref.Path)
		return data, filepath.Base(ref.Path), err
	}
	browser := headlessBrowser()
	if browser == "" {
		return nil, "", fmt.Errorf("нет Chrome или Edge, чтобы снять страницу")
	}
	dir, err := os.MkdirTemp("", "telepath-shot")
	if err != nil {
		return nil, "", err
	}
	defer os.RemoveAll(dir)
	png := filepath.Join(dir, "shot.png")
	cmd := exec.Command(browser, "--headless=new", "--hide-scrollbars", "--force-device-scale-factor=2",
		fmt.Sprintf("--window-size=%d,%d", ref.Width, ref.Height), "--virtual-time-budget=3000",
		"--screenshot="+png, "file://"+filepath.ToSlash(ref.Path))
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, "", fmt.Errorf("%v: %s", err, trim(string(out), 200))
	}
	data, err := os.ReadFile(png)
	name := strings.TrimSuffix(filepath.Base(ref.Path), filepath.Ext(ref.Path)) + ".png"
	return data, name, err
}

// a browser that takes pictures without a window: Playwright's headless shell, Chrome, Edge
func headlessBrowser() string {
	var found []string
	if runtime.GOOS == "darwin" {
		found, _ = filepath.Glob(filepath.Join(homeDir(), "Library/Caches/ms-playwright/chromium_headless_shell-*/*/chrome-headless-shell"))
	} else if runtime.GOOS == "windows" {
		found, _ = filepath.Glob(filepath.Join(os.Getenv("LOCALAPPDATA"), "ms-playwright", "chromium_headless_shell-*", "*", "chrome-headless-shell.exe"))
	}
	sort.Strings(found)
	if len(found) > 0 {
		return found[len(found)-1]
	}
	candidates := []string{"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"}
	if runtime.GOOS == "windows" {
		candidates = []string{
			filepath.Join(os.Getenv("ProgramFiles"), "Google", "Chrome", "Application", "chrome.exe"),
			filepath.Join(os.Getenv("ProgramFiles(x86)"), "Microsoft", "Edge", "Application", "msedge.exe"),
		}
	}
	for _, c := range candidates {
		if fileExists(c) {
			return c
		}
	}
	return ""
}
