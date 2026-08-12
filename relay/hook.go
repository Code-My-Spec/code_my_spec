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
	"path/filepath"
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

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Working-Dir", cwd())

	// Only when found. The server reads an empty value as absent anyway, and a
	// header present-but-blank invites the reader to conclude an id was sent
	// and rejected.
	if id := harnessID(cwd()); id != "" {
		req.Header.Set("X-Harness-Id", id)
	}

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

	os.Stdout.Write(body)

	return 0
}

// harnessID reads the id this working copy was issued, walking up from dir.
//
// A published plugin is installed once and serves every checkout, so it cannot
// bake an id into its URLs the way a generated per-harness config does, and it
// cannot take one from the environment either — nothing sets CMS_HARNESS_ID,
// and the server treats an unexpanded "${...}" as absent. `.cms_harness.json`
// has been in every working copy the whole time with the id in it.
//
// Walking up because a hook's cwd is wherever the agent happens to be, which is
// not always the checkout root.
func harnessID(dir string) string {
	for {
		if id := readHarnessID(filepath.Join(dir, ".cms_harness.json")); id != "" {
			return id
		}

		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}

		dir = parent
	}
}

func readHarnessID(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()

	var doc struct {
		HarnessID string `json:"harness_id"`
	}

	if err := json.NewDecoder(f).Decode(&doc); err != nil {
		return ""
	}

	return strings.TrimSpace(doc.HarnessID)
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
