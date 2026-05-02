# Philosophy

Specs exist because this is a system that coding agents operate.
Agents will find any unintended path through the code. Unit tests catch
internal regressions, but they can't catch "the agent talked to the
database directly and got the right answer for the wrong reason." Specs
catch that by refusing to let the test do anything the real user can't.

## Specs are contracts

A spec declares: *when someone uses the system the way it is meant to be
used, this outcome happens.* Every deviation from that framing erodes the
contract.

Three rules fall out of this framing:

1. **Act through the real surface.** Drive the LiveView through
   `Phoenix.LiveViewTest`. Fire agent hooks through the HTTP endpoint.
   Write to the in-memory filesystem for file-based side effects. Never
   call a domain context function to make something happen.

2. **Observe through the real surface.** `then_` steps read the HTTP
   response body, the rendered LiveView, or (rarely) the in-memory
   filesystem. They do not read the DB. A memory-backed problem might
   match what the user would see, but the point of the spec is to prove
   the user *does* see it — so look where the user looks.

3. **Set up through the real surface when you can.** Preferred setup
   path: drive the UI or agent flow that creates the state. When that's
   impossible or absurdly expensive, use a narrow fixture from
   `<App>Spex.Fixtures` — but only for state that already
   originates outside the local app (users, accounts, projects, stories
   that arrive via server sync).

## Two users, two surfaces

| User | Surface | How specs drive it |
|---|---|---|
| Engineer | LiveView (`<App>LocalWeb`) | `live/2`, `form/2`, `render_submit/1`, `render_click/1` |
| Coding agent | Working directory + harness hooks | `Environments.write_file/3`, `post(conn, ~p"/api/hooks/...")` |

Every `when_` step should be framed as one of these two users doing a
single discrete thing. "The engineer toggles require_unit_tests off."
"The stop hook fires with no file changes this turn." If you can't frame
it as a user action, the scenario isn't acceptance-level — it belongs in
a unit test.

## Why the boundary is enforced with `Boundary`

`<App>Spex` is declared with `top_level?: true` and
`deps: [<App>.Environments, <App>Spex.Fixtures, <App>Web,
<App>LocalWeb]`. This means a spec literally cannot compile if it
tries to `alias <App>.Stories` or call `Projects.create_project/2`
directly. The compiler is the enforcement mechanism — the rule doesn't
rely on reviewer vigilance.

`<App>Spex.Fixtures` has `deps: [<App>, <App>Test]` and
is the only escape hatch. Adding a function there is a deliberate
decision to expand what specs can reach.

## Why in-memory, not tmpfs

The spec suite runs against an in-memory filesystem (`InMemoryEnvironment`,
an Agent-backed `{path => {content, mtime}}` store). This isn't just a
speed optimization:

- **Determinism.** `mtime` advances on every write. Sync pipelines that
  key off file changes behave predictably.
- **Isolation.** Each scenario gets its own Agent. No cross-test
  pollution, no "forgot to clean up."
- **Forcing function.** The agent *must* go through
  `Environments.write_file`/`read_file` to do anything. If a code path
  reaches `File.read!` directly, the spec exposes it immediately — the
  memory env doesn't answer those calls.

The WorkingDir plug still hits the real filesystem (`File.dir?`) so
`setup_active_project` plants a stub `mix.exs` in a real tmp dir to
satisfy it, then the env reroutes all *domain* file I/O to memory. The
stub dir is a marker; the memfs is where the content lives.

## When a spec needs external CLI output

Pipelines that shell out (`mix credo`, `mix test`) can't run against the
in-memory env — those tools read the real disk. For these cases, specs
use `ExCliVcr` cassettes recorded from the real test repo at
`../<app>_test_repo/`. See [environment.md](environment.md).
