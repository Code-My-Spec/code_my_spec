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

## Agent Teams (experimental)

This project opts into Claude Code's experimental
[agent teams](https://code.claude.com/docs/en/agent-teams) so spawned
sub-agents can `SendMessage` each other directly instead of only
reporting back to the orchestrator. Required for story 810's
SendMessage-aware dispatch path.

The flag is set in `.envrc` at the project root:

```
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

Run `direnv allow` once after pulling. Claude Code inherits the var
from shell env, so it's active when your shell is cwd'd into this
project tree and unset outside it. No global `~/.claude/settings.json`
change required.

The sub-agent definitions are project-local at `CodeMySpec/agents/`
— `qa.md`, `code-writer.md`, `spec-writer.md`, `bdd-spec-writer.md`,
`test-writer.md`. When agent teams is enabled, spawning any of these
yields a teammate (not just a subagent); teammates auto-load their
project-defined tools and instructions and gain SendMessage between
each other.

Caveats:
- Teammates do not inherit MCP servers or skills from sub-agent
  definitions — those come from project + user settings.
- No nested teams.
- `/resume` loses teammates in in-process mode.

## Logs

The `cms` server and `cms` CLI both write structured logs to disk. They use a
shared logfmt formatter (`CodeMySpec.Logging.LogfmtFormatter`) so a single
parser handles both sources.

### Files

- `~/.codemyspec/server.log` — application logs from the `cms server` binary.
  Rotated at 10 MB × 3 by `:logger_std_h`.
- `~/.codemyspec/server.boot.log` — raw stdout/stderr from the daemonized cms
  binary (BEAM startup messages, `IO.puts`). Not rotated. Useful when the
  server fails before the logger handler installs.
- `~/.codemyspec/cli.log` — application logs from the `cms` CLI binary.
  Rotated at 10 MB × 3.

`cms logs` / `cms logs -f` print and follow `server.log` from any shell.

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
