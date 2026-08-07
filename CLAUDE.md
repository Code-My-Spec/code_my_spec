<!-- code_my_spec:start -->
## CodeMySpec — Development Harness

This project is managed by **CodeMySpec**, a requirements-driven development harness.
Read `.code_my_spec/AGENTS.md` for the full workflow guide.

### How It Works

CodeMySpec tracks every artifact your project needs — specs, tests, implementations,
reviews, BDD scenarios — as a **requirement graph**. Each requirement has prerequisites,
so you always know what to work on next and in what order.

### Your Workflow

1. **`get_next_requirement`** — returns the highest-priority unsatisfied requirement
   whose prerequisites are all met.
2. **`start_task`** — begins work on that requirement. Returns a detailed prompt
   with context, rules, file paths, and instructions.
3. **Do the work** — write the spec, test, implementation, or review as instructed.
4. The harness **automatically evaluates** your output on stop, checking file existence,
   validity, compilation, and test results. If something is wrong, you get feedback.
5. **Repeat** — call `get_next_requirement` again.

### Key Rules

- **Always follow the task prompt.** It contains spec templates, design rules, file paths,
  and test patterns specific to the component you're working on.
- **Read before you write.** The task prompt tells you which specs, rules, and existing
  files to read. Do it.
- **One requirement at a time.** The graph handles ordering. Don't skip ahead.
- Specs live in `.code_my_spec/spec/`, rules in `.code_my_spec/rules/`, architecture in `.code_my_spec/architecture/`.
<!-- code_my_spec:end -->

## Logs

Everything lands in `~/.codemyspec/`. **There are three application logs, not
two** — the split is by *source process*, and grepping the wrong one reads
exactly like "that never happened."

### Files

| Path | Written by | Format | Contains |
|---|---|---|---|
| `~/.codemyspec/server.log` | `cms server` | logfmt, `src=server` | `[StopHook]`, `[Analysis]`, `[Files.ComponentSync]`, `[Validation]`, channel handlers |
| `~/.codemyspec/harness.log` | `cms harness` | logfmt, `src=harness` | **every `[CmsHarness]` line** — scans, manifests, hook refusals, reconnects, analyzer runs |
| `~/.codemyspec/cli.log` | `cms` CLI | plain Logger (`HH:MM:SS.mmm mfa=… [level] msg`) | CLI invocations, `LocalServer`, MCP transport |
| `~/.codemyspec/mix_phx_4004.log` | `mix phx.server` on :4004 | raw stdout | Ecto `QUERY OK` debug, LiveView, compile output |
| `~/.codemyspec/server.boot.log` | BEAM startup | raw stdout | pre-logger boot junk |
| `/opt/homebrew/var/log/codemyspec.log` | `brew services` supervisor | raw stdout/stderr | service-level stdout on macOS (Windows: `C:\ProgramData\CodeMySpec\shawl\`) |

Handler paths are in `CodeMySpec.Logging.default_path/1`; the harness handler is
installed in `code_my_spec_local_web/application.ex`. Rotation is 10 MB × 3 by
`:logger_std_h`, so check `server.log.0/.1/.2` for anything older.

**Harness symptoms are in `harness.log`, not `server.log`.** A hook that refused
(`:no_reply`, `:not_connected`), a manifest that was sent but never accepted, a
reconnect backoff, a dropped analyzer result — all harness-side, none of them in
`server.log`. The matching server-side view (`[StopHook]`, reconcile results) is
in `server.log`. Diagnosing a hook failure usually needs both, interleaved.

### Two harnesses append to one harness.log

If two harnesses are started on the same working copy, both write to the same
file, so a linear read shows **timestamps going backwards** at the splice. Sort
before reasoning about ordering, and treat a non-monotonic timeline as evidence
of a second harness rather than a parsing bug. The lease refusal names it
outright: `not serving <root> — the harness at <root> on <host> already holds
this project`.

### Reading recipes

Timeline for one window, message text only:

    sed -E 's/^ts=[0-9-]+T([0-9:.]+)Z.*msg="([^"]*)".*/\1  \2/' ~/.codemyspec/harness.log \
      | grep -E '^18:2' | sort

Both sides of one incident, merged:

    cat ~/.codemyspec/{server,harness}.log \
      | sed -E 's/^ts=([0-9T:.-]+)Z.*src=([a-z]+).*msg="([^"]*)".*/\1 \2 \3/' \
      | grep -E '^2026-08-07T18:2' | sort

Errors only, any source:

    grep -hE 'level=(warning|error)' ~/.codemyspec/{server,harness}.log | tail -40

### Format

One logfmt event per line:

    ts=2026-05-09T14:23:01.123Z level=info src=server req=abc123 mfa=Foo.Bar.baz/2 msg="..."

Keys are stable: `ts`, `level`, `src` (`server`|`harness`), `mfa`, `msg`, plus any
metadata the call site attached (`request_id` shows up as `request_id=`).
`cli.log` is **not** logfmt and carries no `src=` — parse it separately.
Values containing spaces, `=`, `"`, or newlines are double-quoted with
backslash escaping. Each metadata value is truncated at 500 bytes so a single
giant payload cannot blow the reader's context window.

### Correlating across one CLI invocation

`CodeMySpecCli.CliRunner` stamps a fresh `request_id` for every command
invocation. Grep `request_id=<id>` against `cli.log` to see all log lines from
one `cms` run.

Server-side, Phoenix's `Plug.RequestId` stamps `request_id` per HTTP request,
so all logs inside one MCP tool call (or LiveView mount, or REST handler)
share an id automatically — visible as `request_id=` in `server.log`.

CLI ↔ server correlation across the wire is **not** wired up; CLI commands
mostly act locally and don't push per-command events to the server, so a
shared id wouldn't have anything to tie together today.
