//go:build !darwin && !windows

package main

import "os/exec"

// Elsewhere (Linux): no dialogs yet, the menu and the terminal are enough

const isWindows = false

func notify(title, text string)  {}
func alert(title, text string)   {}
func confirm(text string) bool   { return true }
func chooseFolder() string       { return "" }
func autostartEnabled() bool     { return false }
func setAutostart(on bool) error { return nil }

func openURL(url string) {
	_ = exec.Command("xdg-open", url).Start()
}

func bonjourHost() string { return computerName() }
