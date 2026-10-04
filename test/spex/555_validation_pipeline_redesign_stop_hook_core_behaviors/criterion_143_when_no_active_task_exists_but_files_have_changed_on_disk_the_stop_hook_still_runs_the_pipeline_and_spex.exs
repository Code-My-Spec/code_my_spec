defmodule CodeMySpecSpex.Story555.Criterion5101Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5101 — When no active task exists but files have changed
  on disk, the stop hook still runs the pipeline and analyzers, but
  task evaluation is skipped and the stop is allowed if no blocking
  problems are found.

  Freestyle path: agent writes a clean implementation + spec file,
  fires the stop hook with no session_id. StopController skips task
  evaluation (no session → no task → skip), runs Validation which
  sees `sync_result.changed_paths` as the changed-files window,
  pipeline runs `mix compile` + `mix test --stale` (replayed from
  the shared `clean` cassette) with the clean fixtures producing zero
  problems, so `check_blocking_problems` returns `:ok` and the stop
  is allowed.

  Fixtures under `test/fixtures/validation/pipeline_clean_run/`:
  - `compile.jsonl` — empty (clean compile diagnostics)
  - `exunit.json` — zero failures

  Cassette: `test/fixtures/cassettes/clean.json` — existing clean-path
  recording (compile ok + test ok + credo-with-findings-unused).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.HarnessHooks

  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Freestyle stop hook allows a clean run with no active task", criterion: 143 do
    scenario "agent writes clean files, fires stop with no session, stop allowed" do
      given_ :synced_context_component

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      when_ "the stop hook fires without a session_id", context do
        HarnessHooks.land_analysis(
          context,
          "spex",
          Path.expand("test/fixtures/validation/spex_green.jsonl")
        )

        HarnessHooks.land_analysis(context, "exunit", fixture_path("exunit.json"))
        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))

        response = HarnessHooks.post_hook(context, "stop", %{})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response is the empty allow signal", context do
        assert context.response == %{},
               "freestyle clean run must produce empty allow, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
