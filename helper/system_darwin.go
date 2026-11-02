package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// The Mac's own dialogs and notifications, through osascript; start at login through a LaunchAgent

const isWindows = false

func appleScriptString(s string) string {
	return `"` + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), `"`, `\"`) + `"`
}

func osascript(script string) (string, error) {
	out, err := exec.Command("osascript", "-e", script).Output()
	return strings.TrimSpace(string(out)), err
}

func notify(title, text string) {
	_, _ = osascript("display notification " + appleScriptString(text) + " with title " + appleScriptString(title))
}

func alert(title, text string) {
	_, _ = osascript("display dialog " + appleScriptString(text) + " with title " + appleScriptString(title) + appIcon() + ` buttons {"Понятно"} default button 1`)
}

// the app's own icon in its dialogs, when it runs as Agentgram Helper.app
func appIcon() string {
	icns := filepath.Join(filepath.Dir(executablePath()), "..", "Resources", "AppIcon.icns")
	if _, err := os.Stat(icns); err != nil {
		return ""
	}
	return " with icon (POSIX file " + appleScriptString(icns) + ")"
}

func confirm(text string) bool {
	out, err := osascript("display dialog " + appleScriptString(text) + ` with title "Telepath"` + appIcon() + ` buttons {"Отмена", "Отключить"} default button 1 cancel button 1`)
	return err == nil && strings.Contains(out, "Отключить")
}

func chooseFolder() string {
	out, err := osascript(`POSIX path of (choose folder with prompt "Папка проектов")`)
	if err != nil {
		return ""
	}
	return strings.TrimSuffix(out, "/")
}

func openURL(url string) {
	_ = exec.Command("open", url).Start()
}

func launchAgentPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", "app.agentgram.helper.plist")
}

func autostartEnabled() bool {
	_, err := os.Stat(launchAgentPath())
	return err == nil
}

func setAutostart(on bool) error {
	if !on {
		return os.Remove(launchAgentPath())
	}
	exe := executablePath()
	if exe == "" {
		return fmt.Errorf("no path")
	}
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>app.agentgram.helper</string>
	<key>ProgramArguments</key><array><string>` + exe + `</string></array>
	<key>RunAtLoad</key><true/>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
`
	if err := os.MkdirAll(filepath.Dir(launchAgentPath()), 0o755); err != nil {
		return err
	}
	return os.WriteFile(launchAgentPath(), []byte(plist), 0o644)
}

// The name the Mac itself answers to on the local network (System Settings → Sharing → Local hostname). The host
// name (os.Hostname) can be another one — «Mac» from the router — that nobody answers for, and a phone that found
// the helper then never reaches it
func bonjourHost() string {
	if out, err := exec.Command("scutil", "--get", "LocalHostName").Output(); err == nil {
		if name := strings.TrimSpace(string(out)); name != "" {
			return name
		}
	}
	return computerName()
}
