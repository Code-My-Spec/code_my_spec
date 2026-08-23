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
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Freestyle stop hook allows a clean run with no active task" do
    scenario "agent writes clean files, fires stop with no session, stop allowed" do
      given_ :synced_context_component

      when_ "the stop hook fires without a session_id", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
                "exunit" => fixture_path("exunit.json"),
                "compile" => fixture_path("compile.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

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
