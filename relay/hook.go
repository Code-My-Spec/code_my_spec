package main

// Forwarding a Claude Code hook, as a native binary rather than a shell script.
//
// The plugin's hooks used to be bare `curl` invocations with a static args
// array, which cannot read anything at request time — so the config every
// marketplace user installs named no working copy, and the harness refused it:
// "This hook did not say which working copy it is about."
//
// Routing them through a bash script fixed that and broke Windows. Claude Code
// runs a hook command through cmd.exe there, so `bash` has to be on PATH — Git
// Bash or WSL — which is a regression from curl, and there is no per-platform
// key to fall back on: `commandWindows` appears zero times in the Claude Code
// 2.1.227 binary, against 40 and 53 for known hook keys in the same probe.
//
// This binary already ships in the release bin/ and is put on PATH by every
// packager (brew symlinks it, the MSI harvests bin/), cross-compiled with a
// .exe on Windows. So it is the one thing the hook can name that exists on both
// platforms without assuming a shell.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

const defaultHookPort = "4003"

// runHook reads the hook payload on stdin and POSTs it to endpoint, naming the
// working copy it came from. The reply goes to stdout, which is what Claude
// Code reads the hook's decision from.
func runHook(args []string) int {
	port, endpoint := parseHookArgs(args)
	if endpoint == "" {
		hookUsage()
		return 2
	}

	payload, err := io.ReadAll(os.Stdin)
	if err != nil {
		logf("could not read the hook payload: %v", err)
		return 0
	}
	url := "http://localhost:" + port + endpoint

	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		logf("could not build the request: %v", err)
		return 0
	}

	// Anchored on the payload's own `cwd`, not the process's.
	//
	// Every Claude Code hook payload carries one — it is in the base object
	// every hook_event_name spreads over — and it is the directory the *session*
	// is in. `os.Getwd()` is whatever the hook subprocess happened to inherit,
	// which is usually the same and is not the same thing. Resolving a harness
	// by walking up from an inherited directory is a guess that reads as a fact,
	// and which checkout a hook belongs to is the question this binary exists to
	// answer.
	//
	// Falls back to the process directory, so a payload without one behaves
	// exactly as before rather than losing its id.
	dir := payloadCwd(payload)
	if dir == "" {
		dir = cwd()
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Working-Dir", dir)

	// No id is sent, and none is resolved here.
	//
	// This used to walk up from dir for `.cms_harness.json` and set
	// `X-Harness-Id`. The walk had no boundary: it climbed to the filesystem
	// root, so an un-onboarded checkout nested inside an onboarded one found its
	// *parent's* config and reported its work under an identity that was not its
	// own. Silently, because a found id looks exactly like a correct one.
	//
	// The harness does the walk now, from the `X-Working-Dir` above, and stops
	// at a project boundary — a `.git` or a `mix.exs` — refusing there by name
	// instead of climbing through it. That is one implementation of the rule
	// rather than two in two languages, and it is the one that can say
	// "%s has not been onboarded" with the directory in it.

	client := &http.Client{Timeout: 30 * time.Second}

	resp, err := client.Do(req)
	if err != nil {
		// Silent by design: a hook that cannot reach the server must not break
		// the session it is attached to. The harness says so on its own side.
		logf("%s: %v", endpoint, err)
		return 0
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		logf("could not read the reply: %v", err)
		return 0
	}

	// A refusal that names a missing field says nothing about what did arrive,
	// and this is the only place that sees the payload before anything parses
	// it. `subagent-start` has been answering `{"error":"agent_id is required"}`
	// for days with no way to tell whether Claude Code omitted the field or
	// something between here and the server dropped it — the relay forwards
	// stdin verbatim, so it can settle that in one line.
	//
	// Keys only, never values: hook payloads carry prompts, transcripts and
	// file contents, and none of that belongs in a log to answer "which fields
	// were present".
	if resp.StatusCode >= 400 {
		logf("%s: %d %s — payload carried %s", endpoint, resp.StatusCode,
			strings.TrimSpace(string(body)), payloadKeys(payload))
	}

	os.Stdout.Write(body)

	return 0
}

// payloadCwd reads the working directory Claude Code says the session is in.
//
// Returns "" for a payload that carries none or does not parse, so the caller
// falls back rather than resolving against an empty path — which would walk up
// from the filesystem root and find whatever is nearest to it.
func payloadCwd(payload []byte) string {
	var fields struct {
		Cwd string `json:"cwd"`
	}

	if err := json.Unmarshal(payload, &fields); err != nil {
		return ""
	}

	return strings.TrimSpace(fields.Cwd)
}

// payloadKeys lists the payload's top-level field names, sorted.
func payloadKeys(payload []byte) string {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(payload, &fields); err != nil {
		return "an unparseable body"
	}

	if len(fields) == 0 {
		return "no fields"
	}

	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	return strings.Join(keys, ", ")
}


// The port is an argument rather than a constant, because `hooks.json` is where
// the release packager can see it: it walks the whole plugin tree swapping every
// `4004` token to `4003`, so the source runs against the dev harness and the
// shipped plugin lands on the published binary's port. Baking the default into
// this file would put it outside that sweep and silently strand one of the two.
//
// CODEMYSPEC_PORT still wins, for an ad-hoc setup on neither port.
func parseHookArgs(args []string) (port, endpoint string) {
	port = getenv("CODEMYSPEC_PORT", "")

	for i := 0; i < len(args); i++ {
		if args[i] == "--port" {
			if i+1 < len(args) {
				if port == "" {
					port = args[i+1]
				}
				i++
			}

			continue
		}

		if endpoint == "" {
			endpoint = args[i]
		}
	}

	if port == "" {
		port = defaultHookPort
	}

	return port, endpoint
}

func hookUsage() {
	fmt.Fprintln(os.Stderr, "usage: cms-mcp-relay hook [--port N] /api/hooks/<name>")
}
