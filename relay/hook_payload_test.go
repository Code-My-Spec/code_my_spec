package main

// Which working copy a hook is about, read from the payload rather than
// reckoned from the process.
//
// The relay used to resolve the harness id by walking up from `os.Getwd()` —
// whatever directory the hook subprocess inherited. That is usually the
// session's directory and is not the same fact, and "usually" is how a guess
// gets read as an answer. Every Claude Code hook payload carries the session's
// own `cwd` in the base object each hook_event_name spreads over, so the
// question can be answered instead of estimated.

import (
	"path/filepath"
	"testing"
)

func TestPayloadCwdIsPreferredOverTheProcessDirectory(t *testing.T) {
	got := payloadCwd([]byte(`{"session_id":"s1","cwd":"/Users/j/checkout","hook_event_name":"Stop"}`))

	if got != "/Users/j/checkout" {
		t.Fatalf("payloadCwd = %q, want the session's directory", got)
	}
}

func TestPayloadCwdFallsBackRatherThanReturningRoot(t *testing.T) {
	// The fallback matters more than it looks. An empty string resolves against
	// the filesystem root, and walking up from there finds whatever
	// .cms_harness.json is nearest to it — a wrong id, confidently sent.
	for name, body := range map[string]string{
		"no cwd field":  `{"session_id":"s1","hook_event_name":"Stop"}`,
		"blank cwd":     `{"cwd":"   "}`,
		"not an object": `["nope"]`,
		"not json":      `<html>502 Bad Gateway</html>`,
		"empty":         ``,
	} {
		if got := payloadCwd([]byte(body)); got != "" {
			t.Errorf("%s: payloadCwd = %q, want %q so the caller falls back", name, got, "")
		}
	}
}

func TestHarnessIDResolvesFromThePayloadDirectory(t *testing.T) {
	// End to end for the thing that was actually wrong: given a payload naming
	// a checkout, the id comes from *that* checkout, not from wherever the
	// process happens to be standing.
	dir := t.TempDir()
	write(t, filepath.Join(dir, ".cms_harness.json"), `{"harness_id":"6bc4851f","project_id":"p1"}`)

	elsewhere := t.TempDir()
	inDir(t, elsewhere)

	if id := harnessID(payloadCwd([]byte(`{"cwd":"` + dir + `"}`))); id != "6bc4851f" {
		t.Fatalf("harnessID = %q, want the id of the checkout the payload named", id)
	}

	if id := harnessID(cwd()); id == "6bc4851f" {
		t.Fatal("the process directory should not resolve to that checkout — the test proves nothing otherwise")
	}
}

func TestPayloadKeysNamesFieldsWithoutLeakingValues(t *testing.T) {
	// Keys only, deliberately. Hook payloads carry prompts, transcripts and file
	// contents; none of that belongs in a log written to answer "which fields
	// were present when the server said one was missing".
	got := payloadKeys([]byte(`{"session_id":"s1","agent_type":"qa","prompt":"a secret"}`))

	if got != "agent_type, prompt, session_id" {
		t.Fatalf("payloadKeys = %q, want the field names sorted", got)
	}

	if got == "" || contains(got, "a secret") {
		t.Fatal("payloadKeys must never carry a value")
	}
}

func TestPayloadKeysSaysSoWhenThereIsNothingToName(t *testing.T) {
	if got := payloadKeys([]byte(`not json`)); got != "an unparseable body" {
		t.Errorf("payloadKeys(garbage) = %q", got)
	}

	if got := payloadKeys([]byte(`{}`)); got != "no fields" {
		t.Errorf("payloadKeys(empty) = %q", got)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && filepath.Base(haystack) != needle &&
		indexOf(haystack, needle) >= 0
}

func indexOf(haystack, needle string) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}

	return -1
}
