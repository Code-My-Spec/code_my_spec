# QA Setup Workflow

The `qa_setup` task produces `.code_my_spec/qa/plan.md` — a QA plan
covering every running surface of the app. Multi-router awareness is
required: apps that ship multiple endpoints in one OTP release are
common, and the plan covers all of them or it's wrong.

Work in two phases: **Probe** then **Write**.

## Phase 1: Probe (run BEFORE writing)

Reading config files isn't enough — Phoenix's compile-time `:url`, OAuth
issuer config, and live_session gating only show their real behavior
when you hit them.

### 1. What's actually listening

    lsof -i -P -n | grep LISTEN

Every loopback port the running app exposes deserves a row in the Tools
Registry. Note the PID — multiple ports under one PID means one OTP
release with multiple endpoints (very common).

### 2. Reach each port over HTTP

For every listening port, hit `/`, `/health` (if it exists), and
`/.well-known/oauth-authorization-server` (MCP-aware apps expose this
even when they aren't fully OAuth). Record response codes and any JSON
returned.

    curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:<port>/
    curl -sS http://127.0.0.1:<port>/.well-known/oauth-authorization-server

Watch for **issuer mismatch**: dev configs sometimes return a production
hostname for OAuth metadata, which means minting bearer tokens locally
requires a tunnel — note this in System Issues.

### 3. Map auth surfaces

- **Browser pipelines.** Open `/users/log-in` (or whatever the app uses)
  in Vibium and call `browser_map`. Phoenix forms typically use
  `name="user[email]"`, NOT `id="login_email"` — document the REAL
  selectors. If multiple login forms render on one page (magic-link +
  password is common), document each.
- **API pipelines.** Try one curl with no auth, capture the challenge.
  Note whether it's `X-Api-Key`, `Authorization: Bearer`, session
  cookie, or per-request scope (e.g. `X-Working-Dir`).
- **MCP / SSE pipelines.** POST `initialize` and read the response
  headers. Anubis Streamable HTTP returns `mcp-session-id` plus
  `text/event-stream` for the body, then **subsequent `tools/call`
  requests come back as `202 Accepted` with the actual response
  delivered over the original init stream**. Plain one-shot curl WILL
  NOT work for tool calls. Either use the agent's MCP client tools or
  `mix test` against the server modules — document this either way.

### 4. Identify Repos and DB targets

    grep -rn "use Ecto.Repo\|Ecto.Adapters" config/ lib/

If the app has multiple env-conditional adapters (e.g. `:dev` →
Postgres, `:dev_cli` → SQLite) or multiple Repos, plan a seed script per
target. Show the right `MIX_ENV=…` invocation.

### 5. Verify Vibium screenshot landing dir

`browser_screenshot { filename: "x/y.png" }` ignores the directory
portion on at least some Vibium builds — files land in
`~/Pictures/Vibium/<basename>`. Verify on this box and document the
actual destination.

## Phase 2: Write the plan

Draw only on what you observed in Phase 1. Don't promise selectors,
paths, or headers you haven't verified.

### Required sections (validated, must be non-empty)

- **App Overview** — endpoints, ports, pipelines, auth model. Use a
  table when there's more than one endpoint.
- **Tools Registry** — for each tool (Vibium MCP, curl, mix run, iex):
  when to use it, real example commands, ACTUAL selectors / headers /
  paths from the probe.
- **Seed Strategy** — for each Repo / DB target, the file path, the
  `mix run` (or `MIX_ENV=… mix run`) command, and the credentials it
  prints. If a seed file already shows up in the Inventory section of
  the prompt, reference it; don't promise a duplicate.

### Strongly recommended

- **System Issues** — anything that took >5 min to figure out goes
  here. Examples: "OAuth discovery returns prod hostname on dev box",
  "Vibium screenshot writes to ~/Pictures/Vibium ignoring path",
  "Anubis MCP requires SSE-aware client, plain curl gives 202". Future
  QA agents read this section first.

### Seed scripts (`.exs` only — no bash loops)

Write QA seed scripts to `priv/repo/` prefixed with `qa_` (e.g.
`qa_seeds.exs`). Run via `mix run priv/repo/qa_seeds.exs`. Each `.exs`
boots the BEAM once and runs all logic in-process — NEVER write a bash
script that loops `mix run -e '…'` per entity (cold-boots the BEAM each
time, extremely slow).

Each seed script should:
- Use the app's context modules (`register_user`, `create_account`,
  etc.) — not raw `Repo.insert_all` — so changesets fire.
- Be idempotent — check for existing records before inserting.
- Print credentials and URLs at the end.

For multi-Repo apps, write one script per target: e.g. `qa_seeds.exs`
for the server Repo, `cli_qa_seeds.exs` for the CLI / SQLite Repo.

### Auth scripts (`.sh` in `.code_my_spec/qa/scripts/`)

Write a `.sh` wrapper ONLY for an auth model you confirmed works via
curl during probing. Common pattern: `authenticated_curl.sh` adds the
`X-Api-Key` or `Authorization: Bearer …` header for every call.

- Single-line curl. NEVER multi-line, heredoc, or backslash-continued.
  See `priv/knowledge/qa-tooling.md` for patterns.
- `chmod +x` the file.
- Don't write wrappers for browser sessions — that's Vibium's job.
- Don't write wrappers for MCP transports — see Probe step 3.

## Stop and validate

When done, stop the session. The evaluator parses the plan against the
`qa_plan` document spec — extra H2 sections fail; required sections
with empty bodies fail. Re-run probes if validation surfaces a
contradiction with reality.

## Idempotent re-runs (when a plan already exists)

When the rendered prompt's "Existing Plan" section fires, the plan is
on disk and the agent should **patch** rather than rewrite. Diff
against the current Router Files + Inventory sections and edit only the
sections that drifted:

- **App Overview** — new endpoints, ports, or auth pipelines?
- **Tools Registry** — new MCP servers, new pipelines, broken commands?
- **Seed Strategy** — new seed scripts, removed ones, schema changes?
- **System Issues** — append anything you discover; don't delete
  entries unless the issue is genuinely fixed.

Preserve working scripts and credentials. The plan is institutional
memory — losing a probed selector or a known issue costs the next QA
agent the same hour you spent.
