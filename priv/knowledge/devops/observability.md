# Observability: reading a project's own deployed logs and traces

Story 1116 ("1082"), issue 577de9bb's follow-on. `CodeMySpec.Observability`
reads a project's own ClickHouse telemetry database -- the OpenTelemetry
logs and traces its deployed app already emits. There is no separate setup
here: provisioning (story 1081) is what stands the ClickHouse instance up
and writes the per-project, per-environment credentials this module reads.

## The four tools

All four take the calling scope implicitly (the connection is the scope --
see "Security model" below) and an optional `env` (`"uat"` or `"prod"`,
default `"uat"`). Reachable from `run_script`.

| Tool | What it answers | Key params |
|------|------------------|------------|
| `query_logs` | Log lines in a time window, newest first | `since`, `until`, `level`, `text` (substring), `trace_id`, `limit` |
| `slow_spans` | The slowest spans in a time window | `since`, `min_duration_ms`, `name_like` (substring), `limit` |
| `get_trace` | One request's full span tree plus every log line emitted during it, joined by trace id | `trace_id` (required) |
| `error_summary` | What's going wrong right now, without writing a query: error-level logs and failed spans, each grouped and counted | `since`, `limit` |

`since`/`until` are ISO 8601 timestamps; `since` defaults to one hour ago,
`until` to now. `limit` defaults to 100, capped at 1000 everywhere. A
capped `query_logs`/`slow_spans` result reports `truncated: true` rather
than silently dropping rows -- both fetch `limit + 1` internally and trim,
because a bare SQL `LIMIT` cannot itself tell "exactly this many rows
exist" apart from "there are more past here."

`error_summary` is the first thing to reach for when something is wrong
and there is no trace id yet: it groups `otel_logs` at `SeverityText IN
('ERROR', 'FATAL')` by message, and `otel_traces` at `StatusCode = 'Error'`
by span name, each with a count and `last_seen`. Once a specific trace id
turns up (from a log line, or a failed span), `get_trace` follows it end
to end.

## Not configured yet

`{:error, :not_configured}` -- surfaced as a plain message, not a crash --
means this project has no telemetry set up for that environment yet
(provisioning, story 1081, has not run for it). Say so and point at
provisioning; retrying the same query will not change the answer.

## Security model

Every function connects as *that project's own* read-only ClickHouse user,
resolved from its own secrets (`CLICKHOUSE_URL`/`_USERNAME`/`_PASSWORD`,
per environment) -- never a shared credential, and never a project named
by a caller-supplied argument. None of the four tools take a
`service`/`project` parameter at all; the connection already is the scope,
and whatever that user's own ClickHouse row policy admits is all a query
here can ever see. Adding such a parameter would invite exactly the
widening the row policy already forecloses -- an agent sees only its own
project's logs and traces, and nothing passed to these tools can widen
that.

## Not here

Standing up ClickHouse itself, provisioning a project's telemetry
credentials, and the OpenTelemetry Collector pipeline that writes
`otel_logs`/`otel_traces` are provisioning's own concern (story 1081), not
this module's. This page covers only *reading* what is already flowing;
it does not cover deploying or configuring the telemetry stack itself.
