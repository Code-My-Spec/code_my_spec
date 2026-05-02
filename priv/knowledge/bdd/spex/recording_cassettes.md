# Recording Cassettes for Pipeline Specs

Stop-hook specs exercise the full validation pipeline: file sync, `mix
compile`, static analyzers (credo/sobelow), and runner analyzers
(`mix test --stale`, `mix spex --stale`). To keep specs deterministic,
we record the CLI invocations as `ExCliVcr` cassettes and replay them.

Most `mix` tools emit their machine-readable output to a separate file
pointed at by an environment variable — `EXUNIT_JSON_OUTPUT_FILE` for
tests, `DIAGNOSTICS_OUTPUT` for compile, `--jsonl=...` for spex.
`ExCliVcr` only replays stdout, so the pipeline sees an empty JSON file
on replay and reports no failures regardless of what the cassette says.
To make failure scenarios replayable, we record **both** the CLI cassette
**and** the JSON output file, then plumb `:output_file` options through
`Validation` at replay time.

Everything below assumes the test repo is at
`../<app>_test_repo/` and has `deps` + `_build` ready (run
`mix deps.get` there once).

## Two recording artifacts per scenario

For every pipeline step the scenario needs to fail:

1. **CLI cassette** (`test/fixtures/cassettes/<name>.json`) — captured
   automatically by `use_cmd_cassette` wrapping the stop-hook POST.
2. **JSON output fixture**
   (`test/fixtures/validation/<name>/<tool>.{json,jsonl}`) — captured
   manually by running the tool against the test repo and copying the
   output file.

Both get checked into the repo. A spec wiring both together looks like:

```elixir
use <App>Spex.Case
use ExCliVcr

@fixture_dir "test/fixtures/validation/pipeline_exunit_failure"
defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

# ... inside when_ ...
response =
  use_cmd_cassette "pipeline_exunit_failure", record: :none do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post(~p"/api/hooks/stop", %{
      "test_output_files" => %{
        "exunit" => fixture_path("exunit.json"),
        "compile" => fixture_path("compile.jsonl")
      }
    })
    |> Phoenix.ConnTest.json_response(200)
  end
```

The `test_output_files` key is an optional POST body field that
`StopController` extracts (see
`lib/code_my_spec_local_web/controllers/hooks/stop_controller.ex:extract_test_output_files/1`)
and threads into `Validation.validate_stop/3` as
`compile_output_file` / `exunit_output_file` / `spex_output_file`
options. `Validation` passes them through to
`Compile.execute` / `Tests.execute` / `Spex.execute`, which read the
pre-recorded JSON instead of whatever `mix` would have written to the
temp path. Real Claude Code clients never send this field, so
production behavior is unchanged.

## Real-contract session + task setup

Some specs — like anything exercising `:spex_stale` or a task's declared
analyzers — require a **session with an active task**, because those
analyzers only run when `session.active_task.session_type.analyzers/0`
declares them. Fakery here defeats the point: the contract the agent
uses in production is **`POST /api/hooks/session-start` followed by the
`start_task` MCP tool**, and that is what specs should drive.

This is wrapped in the `:bdd_task_started` shared given (see
[shared_givens.md](shared_givens.md)):

```elixir
given_ :synced_context_component
given_ :story_linked_to_component
given_ :bdd_task_started
```

The given POSTs to `/api/hooks/session-start` with a unique
`session_id`, then invokes
`<App>.McpServers.Tasks.Tools.StartTask.execute/2` with a
`%Anubis.Server.Frame{assigns: %{current_scope: context.scope}}`. This
creates a real active task on the session with
`session_type: AgentTasks.WriteBddSpecs` — whose `analyzers/0` returns
`[:spex_stale]`. It produces `context.session_id`, which the spec then
includes in the stop-hook POST body so the controller resolves the
task.

## Recipe: recording an exunit failure cassette

Scenario name: `pipeline_exunit_failure`. Shared by specs 5088 and
5089.

1. **Prep the test repo.** Add a failing test file. From the main
   project directory:

   ```bash
   cat > ../<app>_test_repo/test/example_context_test.exs <<'EOF'
   defmodule ExampleContextTest do
     use ExUnit.Case

     test "fails on purpose" do
       assert 1 == 2, "exunit failure fixture"
     end
   end
   EOF
   ```

2. **Capture the ExUnit JSON output:**

   ```bash
   cd ../<app>_test_repo
   MIX_ENV=test EXUNIT_JSON_OUTPUT_FILE=/tmp/exunit_failure.json \
     mix test --formatter ClientUtils.TestFormatter --stale

   mkdir -p ../code_my_spec/test/fixtures/validation/pipeline_exunit_failure
   cp /tmp/exunit_failure.json \
      ../code_my_spec/test/fixtures/validation/pipeline_exunit_failure/exunit.json
   ```

3. **Capture a clean compile JSONL.** Delete the failing test first so
   the compile is clean:

   ```bash
   cd ../<app>_test_repo
   rm test/example_context_test.exs
   DIAGNOSTICS_OUTPUT=/tmp/compile_clean.jsonl mix compile --return-errors
   cp /tmp/compile_clean.jsonl \
      ../code_my_spec/test/fixtures/validation/pipeline_exunit_failure/compile.jsonl
   ```

   An empty `compile.jsonl` is the "no compile diagnostics" signal and
   is the common case.

4. **Record the CLI cassette.** In the spec file, flip
   `use_cmd_cassette "<name>", record: :none` to `record: :once`. Delete
   any stale cassette, run the spec, then flip back:

   ```bash
   cd ../code_my_spec
   rm -f test/fixtures/cassettes/pipeline_exunit_failure.json
   # (edit spec to use record: :once)
   mix spex test/spex/553/5089_spex.exs
   # (edit spec back to record: :none)
   ```

5. **Verify replay.** Run the full suite with cassette locked:

   ```bash
   mix spex
   ```

6. **Clean the test repo.** Remove any leftover fixture files you
   wrote:

   ```bash
   rm -f ../<app>_test_repo/test/example_context_test.exs
   ```

7. **Commit** the cassette and JSON fixtures alongside the spec.

## Recipe: recording a spex failure cassette (5090)

Scenario name: `pipeline_spex_failure`. The test repo does not currently
have `:sexy_spex` as a dependency, so we cannot run real `mix spex` in
it — the JSONL fixture is hand-crafted to match the parser's expected
shape (`<App>.BddSpecs.Spex.build_failure/1`). The System.cmd
invocation of `mix spex --stale` is still captured by the cassette, and
because `Spex.execute` reads `:output_file` from opts, the parser picks
up our hand-crafted JSONL.

1. **Write the JSONL fixture** at
   `test/fixtures/validation/pipeline_spex_failure/spex.jsonl`:

   ```json
   {"spex":"intentional failure","scenario":"asserts false","steps":[{"type":"then","description":"fails","status":"failed"}],"error":{"message":"spex failure fixture","file":"test/spex/example_context_spex.exs","line":7,"stacktrace":[]}}
   ```

2. **Copy a clean compile fixture** (reuse the exunit recipe's one):

   ```bash
   cp test/fixtures/validation/pipeline_exunit_failure/compile.jsonl \
      test/fixtures/validation/pipeline_spex_failure/compile.jsonl
   ```

3. **Record the CLI cassette** the same way as the exunit recipe —
   flip to `record: :once`, delete the cassette, run, flip back.
   `mix spex` runs in `scope.cwd` (the stub dir with only a dummy
   `mix.exs`), so `System.cmd` exits non-zero; that's fine because
   the JSONL fixture drives failure parsing.

4. **Commit** both the cassette and the JSONL fixture.

### When sexy_spex is added to the test repo

If the test repo later adopts `:sexy_spex`, regenerate the JSONL by
actually running it:

```bash
cd ../<app>_test_repo
mkdir -p test/spex
cat > test/spex/failing_example_spex.exs <<'EOF'
defmodule TestPhoenixProject.FailingSpex do
  use SexySpex
  spex "intentional failure" do
    scenario "asserts false" do
      then_ "fails", _context do
        assert 1 == 2, "spex failure fixture"
        :ok
      end
    end
  end
end
EOF

mix spex test/spex/failing_example_spex.exs --jsonl=/tmp/spex_failure.jsonl

cp /tmp/spex_failure.jsonl \
   ../code_my_spec/test/fixtures/validation/pipeline_spex_failure/spex.jsonl
rm test/spex/failing_example_spex.exs
```

## Recipe: untouched-component scenario (5088)

Scenario: an exunit failure exists on a component *not* touched this
turn, and `block_changed` renders it advisory.

The honest flow fires the stop hook **twice**:

- Turn 1 seeds the problem by driving the real pipeline against a
  freshly-written failing test file. Cassette records
  `mix compile` + `mix test --stale` (failure).
- Turn 2 fires the stop hook with **no file changes** since turn 1.
  `FileSync` reports no changes, the pipeline is skipped entirely,
  `check_blocking_problems` consults the persisted problem from turn
  1, and `block_changed` with empty `changed_component_ids` demotes
  it to advisory. No new System.cmd calls — nothing to record for
  turn 2.

5088 reuses 5089's `pipeline_exunit_failure` cassette and JSON
fixtures. The spec's `given_` does both POSTs in sequence; only the
first is wrapped in `use_cmd_cassette`, and the `then_` asserts on
turn 2's response.

## Matching behavior notes

`ExCliVcr`'s default `match_on: [:command, :args]` ignores the `:env`
and `:cd` opts when looking up a recording. That's why the
`EXUNIT_JSON_OUTPUT_FILE` env value in `Tests.execute` doesn't break
matching across runs. When you pass `:output_file` through
`test_output_files`, it becomes stable across runs (the fixture path).

For `Spex.execute` and the cassette for `mix spex`, the `--jsonl=...`
flag IS in `args`. Always pass the same fixture path so args match.

Do not add `:env` or `:cd` to `match_on` for these cassettes.

## Gotchas

### `mix spex <path>` runs the whole directory, not just that file

`mix spex test/spex/553/5089_spex.exs` still runs every spec file under
`test/spex/`. Do not assume passing a path narrows execution. When
recording a single cassette, either delete the other specs' cassettes
temporarily, or accept that unrelated specs will also try to use the
recording session — which matters because of the next gotcha.

### Concurrent specs racing a shared cassette

When two specs share a cassette name (e.g. 5088 and 5089 both use
`pipeline_exunit_failure`), `record: :once` writes the cassette only
after the recording block finishes. If both specs run concurrently,
the second may try to replay before the first has written — and fail
with `CassetteNotFoundError`.

Workflow: record ONE spec at a time by flipping only that spec to
`record: :once`, running the suite, letting the cassette be written,
then flipping back to `:none`. Only after every spec with a unique
cassette is locked to `:none` should the suite be run end-to-end.

### Empty fixture files are load-bearing

A clean compile produces an empty `DIAGNOSTICS_OUTPUT` file
(`compile.jsonl`, 0 bytes). `Compile.execute` interprets this as "no
diagnostics" via the `{:ok, ""}` branch. Don't "helpfully" fill the
file with `[]` or `{}` — it must be empty. Same for `mix spex` with no
failures (the JSONL is just empty).

### Stub `scope.cwd` means compile exits non-zero

The memfs-backed env's `cwd` is a real tmp dir containing only a stub
`mix.exs`. When the cassette replay fires `mix compile --return-errors`
in that dir during recording, it exits 1 (no real project). That's
fine — `Compile.execute` still reads `DIAGNOSTICS_OUTPUT` and returns
`[]` when the file is empty, so `run_pipeline` treats it as a clean
compile. If your scenario needs a non-empty diagnostics output, pre-
populate `compile.jsonl` accordingly.

## Staleness

Cassettes + JSON fixtures go stale when:

- The CLI changes flags (rare — `mix test --stale` is stable).
- The `ClientUtils.TestFormatter` output schema changes.
- `Compile.execute` / `Tests.execute` / `Spex.execute` start parsing
  new fields.

Re-record by following the recipe. Every recording recipe assumes
`../<app>_test_repo/` is clean — run `git status` there after
recording to make sure you haven't left fixture test files behind.

## Never commit test-repo side effects

The test repo is shared across specs. Any file you write to it during
recording must be removed before committing (the cleanup step in each
recipe). A stray `example_context_test.exs` there will break every
other spec's recordings next time they re-record.
