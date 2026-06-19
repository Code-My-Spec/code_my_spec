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

The `cms` server and `cms` CLI both write structured logs to disk. They use a
shared logfmt formatter (`CodeMySpec.Logging.LogfmtFormatter`) so a single
parser handles both sources.

### Files

- `~/.codemyspec/server.log` — application logs from the `cms server` binary.
  Rotated at 10 MB × 3 by `:logger_std_h`.
- The service supervisor captures raw stdout/stderr (BEAM startup messages,
  `IO.puts` before the logger handler installs): `/opt/homebrew/var/log/codemyspec.log`
  on macOS (`brew services`), `C:\ProgramData\CodeMySpec\shawl\` on Windows.
- `~/.codemyspec/cli.log` — application logs from the `cms` CLI binary.
  Rotated at 10 MB × 3.

Read `server.log` directly (`tail -f ~/.codemyspec/server.log`); lifecycle and
the service log are managed by `brew services` / the Windows Shawl service.

### Format

One logfmt event per line:

    ts=2026-05-09T14:23:01.123Z level=info src=server req=abc123 mfa=Foo.Bar.baz/2 msg="..."

Keys are stable: `ts`, `level`, `src` (`server`|`cli`), `mfa`, `msg`, plus any
metadata the call site attached (`request_id` shows up as `request_id=`).
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
