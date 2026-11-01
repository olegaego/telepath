package main

import (
	"os/exec"
	"strings"
	"syscall"
)

// Windows' own dialogs through PowerShell, start at login through the Run key of the user

const isWindows = true

func powershell(script string) (string, error) {
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

func psString(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func notify(title, text string) {
	_, _ = powershell(`Add-Type -AssemblyName System.Windows.Forms; $n = New-Object System.Windows.Forms.NotifyIcon; $n.Icon = [System.Drawing.SystemIcons]::Information; $n.Visible = $true; $n.ShowBalloonTip(8000, ` + psString(title) + `, ` + psString(text) + `, 'Info'); Start-Sleep 9; $n.Dispose()`)
}

func alert(title, text string) {
	_, _ = powershell(`Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show(` + psString(text) + `, ` + psString(title) + `) | Out-Null`)
}

func confirm(text string) bool {
	out, _ := powershell(`Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show(` + psString(text) + `, 'Agentgram', 'OKCancel')`)
	return out == "OK"
}

func chooseFolder() string {
	out, err := powershell(`Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = 'Папка проектов'; if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }`)
	if err != nil {
		return ""
	}
	return out
}

func openURL(url string) {
	_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
}

const runKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

func autostartEnabled() bool {
	return exec.Command("reg", "query", runKey, "/v", "Telepath").Run() == nil
}

func setAutostart(on bool) error {
	if !on {
		return exec.Command("reg", "delete", runKey, "/v", "Telepath", "/f").Run()
	}
	return exec.Command("reg", "add", runKey, "/v", "Telepath", "/t", "REG_SZ", "/d", `"`+executablePath()+`"`, "/f").Run()
}
