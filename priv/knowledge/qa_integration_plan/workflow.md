# QA Integration Plan Workflow

The `qa_integration_plan` task identifies third-party integrations from
the project's technical decisions (ADRs) and produces:

- One integration spec per service (`.code_my_spec/integrations/<name>.md`).
- A runnable verify script per integration
  (`.code_my_spec/qa/scripts/verify_<name>.sh`).
- An OAuth2 token-exchange script when applicable
  (`.code_my_spec/qa/scripts/exchange_<name>_token.sh`).
- An integration index (`.code_my_spec/integrations/index.md`).

Each spec moves from `status: pending` → `status: verified` once its
verify script runs and returns `"status": "ok"`.

## Six-step procedure

### 1. Identify integrations

Read all decision records in `.code_my_spec/architecture/decisions/`.
For each decision that references a third-party service (OAuth
provider, API service, external integration), note:

- Service name (e.g. `twilio`, `google_calendar`, `stripe`).
- Auth type: `api_token` or `oauth2`.
- Required credentials and the env var names that hold them.

If no integrations are needed, write an integration index stating
"No integrations required" and stop the session.

### 2. Draft integration specs

For each identified integration, write a spec to
`.code_my_spec/integrations/<name>.md` matching the
`integration_spec` document type (the prompt includes the spec
projection). Set initial `status: pending`.

### 3. Generate verify scripts

For each integration, write a verify script to
`.code_my_spec/qa/scripts/verify_<name>.sh`. The script:

- Reads credentials from environment variables.
- Makes a real API call that proves the credentials work.
- Outputs structured JSON to stdout:

```json
{"integration": "name", "status": "ok", "details": "what was verified"}
```

  or on failure:

```json
{"integration": "name", "status": "error", "error": "message", "details": "what went wrong"}
```

- Is executable (`chmod +x`).

For OAuth2 integrations, also write
`.code_my_spec/qa/scripts/exchange_<name>_token.sh` that exchanges
client credentials for a test access token.

### 4. Request credentials from the user

Tell the user exactly which environment variables need to be set,
where to get the values, and how to provide them. Be specific —
include URLs to the relevant developer consoles. The engineer is
the only one who can produce real credentials.

### 5. Verify credentials

Once the engineer provides credentials:

1. Run each verify script.
2. Check stdout for `"status": "ok"`.
3. Update the integration spec's `status` field to `verified`.

If verify fails, surface the error to the engineer and iterate
(wrong credential, wrong scope, account not yet provisioned, etc.).

### 6. Write the integration index

Write `.code_my_spec/integrations/index.md` summarizing every
integration and its status. The evaluator requires this index
plus per-spec verification (every spec must contain "verified").

## Done signal

Evaluator state machine:

1. If no spec files exist → `:valid` (no integrations needed).
2. Otherwise: integration index exists + every spec has a verify
   script on disk + every spec contains "verified" → `:valid`.
3. Any check fails → `:invalid` with feedback naming the gap.

## Anti-patterns

- **Drafting specs without running verify** — the spec contract
  requires real verification, not "I think the credentials work."
- **Hardcoding credentials in verify scripts** — env vars only.
- **Skipping the index** — even if specs exist and are verified,
  no index = invalid.
- **Marking pending specs as verified** without re-running the
  script. The status field is the engineer's audit trail.
