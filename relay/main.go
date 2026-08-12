// cms-mcp-relay is a thin stdio <-> HTTP bridge for the CodeMySpec MCP server.
//
// Claude Code spawns this binary and speaks MCP JSON-RPC over stdin/stdout.
// The relay forwards each message to the one running `cms server` over its
// Anubis streamable-HTTP endpoint (POST /mcp?dir=<cwd>) and writes the server's
// responses back to stdout. It holds no state beyond the HTTP session id.
//
// Why a standalone binary and not the Elixir app: the host talks to a process it
// spawns; the running server is a separate daemon it can't attach stdio to. So
// a spawned bridge is unavoidable — but it should be a fast-starting, no-runtime
// byte-shuffler, not a second BEAM boot behind a release launcher + env.sh.
//
// # Claude Code no longer needs this
//
// That reasoning was never true of Claude Code, which speaks remote MCP itself.
// Verified against a real sprite: a plugin manifest declaring
//
//	{"type": "http", "url": "...", "headers": {"Authorization": "Bearer ...", ...}}
//
// reports `✔ Connected` with no relay process at all, and the agent then drove
// `get_next_requirement` and `list_stories` through it. The last apparent
// justification — that only a spawned process can compute the caller's working
// directory for `?dir=` — does not hold either: Claude Code interpolates
// `${CLAUDE_PROJECT_DIR}` inside the URL, confirmed by a probe param arriving
// server-side already substituted. `plugins/claude` therefore ships an `http`
// server and never spawns this.
//
// It stays for `plugins/codex` and `plugins/antigravity`, which still declare it
// by command. Whether those hosts support a remote MCP server has not been
// tested, and breaking two ports on an assumption is not worth the deletion.
// Test them; if they do, this binary and its build steps in mix.exs, the
// Dockerfile and release-extension.yml all come out together.
//
// Config (env):
//
//	CMS_MCP_BASE_URL   base URL of the running server (default http://localhost:4003)
//	CMS_MCP_TOKEN      bearer token, when the endpoint is the CodeMySpec server
//	                   rather than a local `cms server`. The server's harness
//	                   mount takes an OAuth token; a sprite trades its deploy
//	                   key for one (POST /api/sprite/token) and passes it here.
//	CMS_PROJECT_ID     the project to act on, when there is no local server to
//	                   resolve one from a directory. The server has no disk and
//	                   cannot look a path up, so it is told the id outright.
//	CLAUDE_PROJECT_DIR the project directory the server resolves scope from
//	                   (default: the process cwd). Passed as ?dir= on every
//	                   request — Anubis only honors custom headers on POSTs, not
//	                   its SSE GET, so the query param is what rides everywhere.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
)

const defaultBaseURL = "http://localhost:4003"

// capabilities is what `cms-mcp-relay capabilities` prints, and the only way
// to tell this binary from one that predates the hook subcommand.
//
// A relay without `hook` does not reject `hook /api/hooks/stop` — argv[1] is
// not a flag it knows, so it falls through to the MCP path, posts the hook
// payload to /mcp?dir=, gets a JSON-RPC parse error back and exits 0. Claude
// Code reads 0 as a hook that ran. Eight hooks, all silently dead, and the
// only symptom is that nothing the harness should have decided ever happens.
//
// The probe is a marker rather than a version number because the question is
// never "which version" but "can it do this", and an old binary answering the
// probe at all is the thing that cannot happen: it has no `capabilities`
// branch either, so it relays stdin instead and prints nothing.
const capabilities = "cms-mcp-relay hooks=1"

func main() {
	// `hook <endpoint>` forwards a Claude Code hook instead of relaying MCP.
	// Same binary because the same binary is what every packager already puts
	// on PATH, with a .exe on Windows — which is the whole reason the hooks
	// need it. See hook.go.
	if len(os.Args) > 1 && os.Args[1] == "hook" {
		os.Exit(runHook(os.Args[2:]))
	}

	// Asked by `mix cms.harness.onboard` before it writes a hooks.json that
	// depends on the branch above.
	if len(os.Args) > 1 && os.Args[1] == "capabilities" {
		fmt.Println(capabilities)
		os.Exit(0)
	}

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

		// Until a session exists, one at a time.
		//
		// Fanning every line out to its own goroutine loses ordering, and the
		// first two messages are the two that cannot be reordered: `initialize`
		// establishes the session and its response header carries the id that
		// every later request needs. `notifications/initialized` follows
		// immediately, won the race, and arrived at a server that had no session
		// yet — which answered `-32600 Session not found`, an error response to a
		// notification, and Claude Code closed the transport about ten
		// milliseconds in. Reproduced by hand against the installed binary.
		//
		// The cost is bounded: this serializes exactly the handshake. Once the
		// session id is known, parallel tool calls fan out as before.
		r.wg.Add(1)
		if r.getSID() == "" {
			r.forward(line)
		} else {
			go r.forward(line)
		}
	}
	// stdin closed (Claude ended the session): drain in-flight work, then exit.
	r.wg.Wait()
}

// isNotification reports whether a client->server message is a JSON-RPC
// notification: an object with no `id`. Notifications must not be answered, so
// whatever comes back for one must not reach stdout.
func isNotification(msg string) bool {
	var probe struct {
		ID     *json.RawMessage `json:"id"`
		Method string           `json:"method"`
	}
	if err := json.Unmarshal([]byte(msg), &probe); err != nil {
		// Not an object we can read — forward it and let the server judge.
		return false
	}
	return probe.Method != "" && probe.ID == nil
}

// forward POSTs one message and streams the response back to stdout.
func (r *relay) forward(msg string) {
	defer r.wg.Done()

	// A notification gets no reply, by the spec. This server answers
	// `notifications/initialized` with 202 and a body of `{}`, and relaying that
	// `{}` to stdout is what killed the transport: Claude Code validates each
	// stdout line as a JSON-RPC message, `{}` is not one, and the whole MCP
	// server dies about ten milliseconds into the session. Every tool the
	// harness offers then reads as "the plugin has no tools", which looks like a
	// failed install and is not one. An agent lost a full run to this and had to
	// hand-roll its own HTTP bridge to get any tools at all.
	//
	// Sent anyway — the server needs it, it is how a session becomes ready.
	// Only the reply is dropped.
	swallow := isNotification(msg)

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
	// Both optional, and absent for a local `cms server` — that one resolves
	// scope from the directory and needs no credential, because reaching it at
	// all already means being on the machine. They are set when the endpoint is
	// the CodeMySpec server, which has neither the disk to resolve a path nor a
	// reason to trust the caller.
	//
	// Headers rather than query params: unlike ?dir=, these only ever ride
	// POSTs, and this relay makes no other kind of request.
	if tok := os.Getenv("CMS_MCP_TOKEN"); tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	if pid := os.Getenv("CMS_PROJECT_ID"); pid != "" {
		req.Header.Set("X-Project-ID", pid)
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
	if swallow {
		io.Copy(io.Discard, resp.Body)
		return
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

// isJSONRPC reports whether a payload is something Claude Code will accept on
// stdout: a JSON-RPC message, or a batch of them.
func isJSONRPC(s string) bool {
	var one struct {
		JSONRPC string `json:"jsonrpc"`
	}
	if err := json.Unmarshal([]byte(s), &one); err == nil {
		return one.JSONRPC != ""
	}

	var batch []struct {
		JSONRPC string `json:"jsonrpc"`
	}
	if err := json.Unmarshal([]byte(s), &batch); err == nil && len(batch) > 0 {
		return batch[0].JSONRPC != ""
	}

	return false
}

func (r *relay) writeLine(s string) {
	// Belt to the notification braces. Anything on stdout that is not a JSON-RPC
	// message takes the whole transport down with it, so a payload we cannot
	// vouch for goes to the log instead — a dropped line degrades one call, a
	// bad line ends the session.
	if !isJSONRPC(s) {
		logf("dropped a non-JSON-RPC payload rather than breaking the transport: %.200s", s)
		return
	}

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
