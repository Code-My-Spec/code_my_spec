# Environment — memfs, hooks, cassettes

A spec's "world" is three things glued together:

1. An **in-memory filesystem** that stands in for the working directory.
2. A **stub directory** on real disk with a `mix.exs` so the
   `WorkingDir` plug is happy.
3. **Cassettes** that replay `System.cmd` output when a pipeline step
   needs to shell out.

## The in-memory environment

`test/support/in_memory_environment.ex` implements
`<App>.Environments.EnvironmentsBehaviour`. Each call to
`Environments.create(:memory, ...)` spawns an isolated `Agent` whose
state is `%{path => {content, mtime}}`.

Key properties:

- All paths are normalized and stored **relative to `env.cwd`**. Writing
  `"lib/foo.ex"` and writing `"<cwd>/lib/foo.ex"` store under the same key.
- `mtime` advances on every write. This is what makes
  `FileSync.sync_changed/2` detect updates within a single spec run.
- Glob compiles `**` → `.*` and `*` → `[^/]*`. Behaves like a real
  shell glob for the patterns sync pipelines use.
- `ensure_dir/2` is a no-op. The memfs has no directories, just keys.

### Fixture entry point

```elixir
env = Fixtures.memory_environment_fixture(working_dir: "/memfs/env-42")
:ok = Environments.write_file(env, "lib/foo.ex", "...")
{:ok, "..."} = Environments.read_file(env, "lib/foo.ex")
```

`setup_active_project` does all the wiring for you — the env it creates
is attached to the scope and registered so LiveViews that rebuild scope
via `Scope.for_local_project/1` get *this* env, not a default `:local` one.

## The stub directory

The `WorkingDir` plug checks `File.dir?(project.local_path)` directly.
Since the memfs doesn't satisfy that, `setup_active_project` creates a
real tmp dir with a single `mix.exs` file in it. This dir is only a
marker for the plug — every real file read/write in the spec goes
through the memfs.

```elixir
# From code_my_spec_spex_case.ex
stub_dir = Path.join(System.tmp_dir!(), "spex-#{...}")
File.mkdir_p!(stub_dir)
File.write!(Path.join(stub_dir, "mix.exs"), "# stub for WorkingDir plug\n")
ExUnit.Callbacks.on_exit(fn -> File.rm_rf(stub_dir) end)
```

`context.scope.cwd` is this stub dir. When you post to a hook endpoint,
use `context.scope.cwd` for the `x-working-dir` header.

## The three ways state changes in a spec

| Change | How to trigger it | What to observe |
|---|---|---|
| Engineer clicks a button | `render_click/1`, `render_submit/1` on a LiveView | Re-render, `has_element?/2`, subsequent LiveView navigation |
| Agent writes a file | `Environments.write_file/3` + run the real sync flow through the UI (e.g. the `/sync` page's button) | The synced row via `Fixtures.get_component_by_module_name/2` or a rendered graph page |
| Agent signals a hook | `post(conn, ~p"/api/hooks/stop", payload)` with `x-working-dir` header | JSON response body |

## Cassettes for CLI-driven steps

Some pipeline steps shell out — `mix compile`, `mix credo`, `mix test`.
These tools read the real disk, so the memfs can't answer their calls.
For those scenarios, specs use `ExCliVcr` cassettes recorded against
a real fixture repo (e.g. `../<app>_test_repo/`).

```elixir
use <App>Spex.Case
use ExCliVcr

# ...

when_ "the stop hook fires", context do
  response =
    use_cmd_cassette "credo_violation", record: :none do
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(~p"/api/hooks/stop", %{})
      |> Phoenix.ConnTest.json_response(200)
    end

  {:ok, Map.put(context, :response, response)}
end
```

`record: :none` means the spec will fail if a new `System.cmd` is
invoked that's not in the cassette — the suite stays deterministic.

### Recording a new cassette

1. Delete the cassette file in `test/fixtures/cassettes/`.
2. Ensure a fixture repo (e.g. `../<app>_test_repo/`) exists and has whatever state
   the pipeline step needs to observe (violation source file, failing
   test, etc.).
3. Run the spec. ExCliVcr will execute real commands and write the
   cassette.
4. Commit the cassette file alongside the spec.

See [recording_cassettes.md](recording_cassettes.md) for the
spec-specific recipe (cassette + JSON output fixtures + session/task
setup through the real contract).

### When a cassette is not worth it

If the scenario is really about a *decision* downstream of the CLI
output (e.g. "the blocking check classifies this problem as
advisory"), seeding a `Problem` via `Fixtures.problem_fixture/2` is a
pragmatic shortcut — as long as another spec covers the end-to-end
path that would produce the same problem. See
[boundaries.md](boundaries.md) for the anti-pattern discussion
(5088 vs 5087).

## Environment gotchas

- **Paths in the memfs are relative to `env.cwd`.** Don't prefix
  `/memfs/...` when calling `write_file` — pass the same path shape
  sync is going to look for (`"lib/foo.ex"`,
  `".code_my_spec/spec/foo.spec.md"`, etc.).
- **FileSync wipes problems for missing files.** If you seed a
  `Problem` against `lib/example_context.ex`, make sure that file
  exists in the memfs (the `:synced_context_component` given writes
  it). Otherwise sync will clear your seeded problem on its next run.
- **The LiveView rebuilds scope from the DB.** That's why
  `setup_active_project` calls `register_environment/2` — the
  rebuilt scope needs to find the same memfs agent, not a fresh one.
