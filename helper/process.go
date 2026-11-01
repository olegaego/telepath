package main

import (
	"bufio"
	"io"
	"os/exec"
	"strings"
	"sync"
)

// The run of an engine's CLI (Claude Code, Codex) for one turn: started in the project's folder, its output read line
// by line, killed by «СТОП». Both engines' turns embed it.
type engineProcess struct {
	mu  sync.Mutex
	cmd *exec.Cmd
}

func (p *engineProcess) Stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cmd != nil && p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
}

// Starts the CLI; its lines come from the scanner, the end of its stderr is kept for the error
func (p *engineProcess) start(binary string, args []string, cwd string) (*bufio.Scanner, *strings.Builder, error) {
	cmd := exec.Command(binary, args...)
	cmd.Dir = cwd
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}
	var stderr strings.Builder
	cmd.Stderr = &limitedWriter{b: &stderr, max: 2000}
	p.mu.Lock()
	p.cmd = cmd
	p.mu.Unlock()
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	sc := bufio.NewScanner(io.Reader(out))
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	return sc, &stderr, nil
}

// Waits for the CLI to exit after its output ended
func (p *engineProcess) finish() {
	p.mu.Lock()
	cmd := p.cmd
	p.mu.Unlock()
	if cmd != nil {
		_ = cmd.Wait()
	}
	p.mu.Lock()
	p.cmd = nil
	p.mu.Unlock()
}
