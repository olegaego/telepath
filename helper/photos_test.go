package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTakePhotos(t *testing.T) {
	text := "Вот экран.\n\n[[фото: screens/1.html]]\n[[фото: ~/a.png]]\n[[фото: /tmp/b.html 1280x800]]\n\n\nГотово."
	clean, refs := takePhotos(text, "/work")
	if clean != "Вот экран.\n\nГотово." {
		t.Fatalf("text %q", clean)
	}
	want := []photoRef{{"/work/screens/1.html", 390, 844}, {filepath.Join(homeDir(), "a.png"), 390, 844}, {"/tmp/b.html", 1280, 800}}
	if len(refs) != len(want) {
		t.Fatalf("refs %+v", refs)
	}
	for i := range want {
		if refs[i] != want[i] {
			t.Fatalf("ref %d %+v, want %+v", i, refs[i], want[i])
		}
	}
}

func TestPhotoAsItIs(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "p.png")
	_ = os.WriteFile(path, []byte("png"), 0o644)
	data, name, err := renderPhoto(photoRef{Path: path})
	if err != nil || string(data) != "png" || name != "p.png" {
		t.Fatalf("%q %q %v", data, name, err)
	}
}

func TestHTMLBecomesAPicture(t *testing.T) {
	if headlessBrowser() == "" {
		t.Skip("no browser here")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "screen.html")
	_ = os.WriteFile(path, []byte("<html><body style='background:#3390EC'>Telepath</body></html>"), 0o644)
	data, name, err := renderPhoto(photoRef{Path: path, Width: 390, Height: 844})
	if err != nil || name != "screen.png" || len(data) < 8 || string(data[1:4]) != "PNG" {
		t.Fatalf("%d bytes %q %v", len(data), name, err)
	}
}
