package main

import (
	"io"
	"os"
	"strings"
	"testing"
)

func write(t *testing.T, path, body string) {
	t.Helper()

	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func inDir(t *testing.T, dir string) {
	t.Helper()

	prev, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}

	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() { os.Chdir(prev) })
}

// httptest listens on a random port; the hook builds its URL from
// CODEMYSPEC_PORT, so point that at the one it got.
func withPortOf(t *testing.T, serverURL string) {
	t.Helper()

	i := strings.LastIndex(serverURL, ":")
	if i < 0 {
		t.Fatalf("could not read a port out of %q", serverURL)
	}

	t.Setenv("CODEMYSPEC_PORT", serverURL[i+1:])
}

func withStdin(t *testing.T, body string, fn func()) {
	t.Helper()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}

	prev := os.Stdin
	os.Stdin = r

	go func() {
		w.WriteString(body)
		w.Close()
	}()

	defer func() { os.Stdin = prev }()

	fn()
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}

	prev := os.Stdout
	os.Stdout = w

	fn()

	w.Close()
	os.Stdout = prev

	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}

	return string(out)
}
