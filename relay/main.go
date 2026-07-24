// cms-mcp-relay is a thin stdio <-> HTTP bridge for the CodeMySpec MCP server.
//
// Claude Code spawns this binary and speaks MCP JSON-RPC over stdin/stdout.
// The relay forwards each message to the one running `cms server` over its
// Anubis streamable-HTTP endpoint (POST /mcp?dir=<cwd>) and writes the server's
// responses back to stdout. It holds no state beyond the HTTP session id.
//
// Why a standalone binary and not the Elixir app: Claude talks to a process it
// spawns; the running server is a separate daemon it can't attach stdio to. So
// a spawned bridge is unavoidable — but it should be a fast-starting, no-runtime
// byte-shuffler, not a second BEAM boot behind a release launcher + env.sh.
//
// Config (env):
//   CMS_MCP_BASE_URL   base URL of the running server (default http://localhost:4003)
//   CLAUDE_PROJECT_DIR the project directory the server resolves scope from
//                      (default: the process cwd). Passed as ?dir= on every
//                      request — Anubis only honors custom headers on POSTs, not
//                      its SSE GET, so the query param is what rides everywhere.
package main

import (
	"bufio"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
)

const defaultBaseURL = "http://localhost:4003"

func main() {
	base := getenv("CMS_MCP_BASE_URL", defaultBaseURL)
	dir := resolveDir()
	endpoint := strings.TrimRight(base, "/") + "/mcp?dir=" + url.QueryEscape(dir)

	r := &relay{
		endpoint: endpoint,
		client:   &http.Client{},
		out:      bufio.NewWriter(os.Stdout),
	}
	r.run()
}

type relay struct {
	endpoint string
	client   *http.Client

	outMu sync.Mutex
	out   *bufio.Writer

	sidMu     sync.Mutex
	sessionID string

	wg sync.WaitGroup
}

// run reads one JSON-RPC message per line from stdin and forwards each. Every
// message is POSTed in its own goroutine so a slow/long-running call never
// blocks reading the next message from Claude; JSON-RPC ids let the client
// match responses regardless of arrival order.
func (r *relay) run() {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 64*1024), 32*1024*1024) // tolerate large payloads
	for in.Scan() {
		line := strings.TrimSpace(in.Text())
		if line == "" {
			continue
		}
		r.wg.Add(1)
		go r.forward(line)
	}
	// stdin closed (Claude ended the session): drain in-flight work, then exit.
	r.wg.Wait()
}

// forward POSTs one message and streams the response back to stdout.
func (r *relay) forward(msg string) {
	defer r.wg.Done()

	req, err := http.NewRequest(http.MethodPost, r.endpoint, strings.NewReader(msg))
	if err != nil {
		logf("build request: %v", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	if sid := r.getSID(); sid != "" {
		req.Header.Set("Mcp-Session-Id", sid)
	}

	resp, err := r.client.Do(req)
	if err != nil {
		logf("post: %v", err)
		return
	}
	defer resp.Body.Close()

	if sid := resp.Header.Get("Mcp-Session-Id"); sid != "" {
		r.setSID(sid)
	}
	r.emit(resp)
}

// emit writes the JSON-RPC payload(s) from a response to stdout. Streamable-HTTP
// responses come back as SSE (text/event-stream) — one JSON message per
// `data:` line; a plain application/json body is emitted as-is.
func (r *relay) emit(resp *http.Response) {
	if strings.Contains(resp.Header.Get("Content-Type"), "text/event-stream") {
		sc := bufio.NewScanner(resp.Body)
		sc.Buffer(make([]byte, 64*1024), 32*1024*1024)
		for sc.Scan() {
			line := sc.Text()
			if data, ok := strings.CutPrefix(line, "data:"); ok {
				if data = strings.TrimSpace(data); data != "" {
					r.writeLine(data)
				}
			}
		}
		return
	}
	body, _ := io.ReadAll(resp.Body)
	if s := strings.TrimSpace(string(body)); s != "" {
		r.writeLine(s)
	}
}

func (r *relay) writeLine(s string) {
	r.outMu.Lock()
	defer r.outMu.Unlock()
	r.out.WriteString(s)
	r.out.WriteByte('\n')
	r.out.Flush()
}

func (r *relay) getSID() string {
	r.sidMu.Lock()
	defer r.sidMu.Unlock()
	return r.sessionID
}

func (r *relay) setSID(sid string) {
	r.sidMu.Lock()
	defer r.sidMu.Unlock()
	r.sessionID = sid
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// resolveDir picks the project directory the server resolves scope from.
// CLAUDE_PROJECT_DIR wins when it names a real directory. Some Claude Code
// builds forward the plugin-config placeholder "${CLAUDE_PROJECT_DIR}"
// literally (no env interpolation); that value — and any other non-existent
// path — falls back to the process cwd so the relay still resolves scope
// instead of failing every request (initialize included) with
// "Path does not exist", which leaves the MCP server registering zero tools.
func resolveDir() string {
	if v := os.Getenv("CLAUDE_PROJECT_DIR"); v != "" && !strings.Contains(v, "${") && isDir(v) {
		return v
	}
	return cwd()
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func cwd() string {
	d, err := os.Getwd()
	if err != nil {
		return "."
	}
	return d
}

// logf writes to stderr only — stdout is the MCP JSON-RPC channel and a single
// stray byte there corrupts the protocol.
func logf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "[cms-mcp-relay] "+format+"\n", a...)
}
