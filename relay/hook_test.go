package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// The id is the whole point of routing hooks through this binary: a published
// plugin serves every checkout, so it cannot bake one into its URLs, and
// nothing sets CMS_HARNESS_ID. `.cms_harness.json` has always been there.
func TestHarnessIDWalksUp(t *testing.T) {
	root := t.TempDir()
	nested := filepath.Join(root, "lib", "deep", "inside")

	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	write(t, filepath.Join(root, ".cms_harness.json"),
		`{"root":"`+root+`","harness_id":"6bc4851f-f735-4590-bb1c-c660619b4019"}`)

	// From the root, and from a directory a hook might actually fire in.
	for _, dir := range []string{root, nested} {
		if got := harnessID(dir); got != "6bc4851f-f735-4590-bb1c-c660619b4019" {
			t.Errorf("harnessID(%q) = %q, want the id from the checkout root", dir, got)
		}
	}
}

// Outside any working copy it must answer empty rather than climb to / and
// hang, or return something it guessed.
func TestHarnessIDOutsideAWorkingCopy(t *testing.T) {
	if got := harnessID(t.TempDir()); got != "" {
		t.Errorf("harnessID = %q, want empty outside a working copy", got)
	}
}

func TestHarnessIDIgnoresUnreadableAndMalformed(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, ".cms_harness.json"), "not json at all")

	if got := harnessID(dir); got != "" {
		t.Errorf("harnessID = %q, want empty for a file that does not parse", got)
	}
}

// End to end against a real server: the payload arrives, the id is named, and
// the reply reaches stdout — which is where Claude Code reads the decision.
func TestRunHookSendsPayloadAndID(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, ".cms_harness.json"), `{"harness_id":"abc-123"}`)

	var gotID, gotDir, gotBody, gotPath string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotID = r.Header.Get("X-Harness-Id")
		gotDir = r.Header.Get("X-Working-Dir")
		gotPath = r.URL.Path
		b := make([]byte, r.ContentLength)
		r.Body.Read(b)
		gotBody = string(b)
		w.Write([]byte(`{"decision":"block"}`))
	}))
	defer srv.Close()

	inDir(t, dir)
	withPortOf(t, srv.URL)

	stdout := captureStdout(t, func() {
		withStdin(t, `{"hook_event_name":"Stop"}`, func() {
			if code := runHook([]string{"/api/hooks/stop"}); code != 0 {
				t.Errorf("runHook exited %d, want 0 — a hook must not fail its session", code)
			}
		})
	})

	if gotID != "abc-123" {
		t.Errorf("X-Harness-Id = %q, want abc-123", gotID)
	}

	if gotDir == "" {
		t.Error("X-Working-Dir was not sent")
	}

	if gotPath != "/api/hooks/stop" {
		t.Errorf("path = %q, want the endpoint it was given", gotPath)
	}

	if gotBody != `{"hook_event_name":"Stop"}` {
		t.Errorf("body = %q, want the payload unchanged", gotBody)
	}

	if stdout != `{"decision":"block"}` {
		t.Errorf("stdout = %q, want the server's reply — that is the hook's decision", stdout)
	}
}

// A hook that cannot reach the server must not break the session it is attached
// to. The harness reports the outage on its own side.
func TestRunHookSurvivesAnUnreachableServer(t *testing.T) {
	inDir(t, t.TempDir())
	t.Setenv("CODEMYSPEC_PORT", "1")

	withStdin(t, `{"hook_event_name":"Stop"}`, func() {
		if code := runHook([]string{"/api/hooks/stop"}); code != 0 {
			t.Errorf("runHook exited %d, want 0 even with nothing listening", code)
		}
	})
}
