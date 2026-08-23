defmodule CodeMySpecSpex.Story555.Criterion5099Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5099 — When compilation fails with errors, the stop hook
  blocks with the compiler diagnostics and no analyzers or tests run.

  `StaticAnalysis.Pipeline.compile/2` returns `{:error, reason}` when
  the compile fixture contains error-severity diagnostics. The
  `with :ok <- StaticAnalysis.compile(...)` in `run_pipeline/5`
  short-circuits, so credo never runs and `mix test --stale` never
  runs.

  This is enforced by the cassette: `pipeline_compile_error.json`
  contains ONLY a `mix compile --return-errors` entry. If the
  pipeline incorrectly continues to `mix test` or `mix credo`, the
  test fails with `CassetteNotFoundError`.

  Fixtures:
  - `test/fixtures/cassettes/pipeline_compile_error.json` — compile
    command only (exit 1, syntax-error stdout).
  - `test/fixtures/validation/pipeline_compile_error/compile.jsonl` —
    one error diagnostic on `lib/example_context.ex:1`.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Compiler errors block the stop and short-circuit the pipeline" do
    scenario "mix compile returns errors → block with compiler reason, no analyzers" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the agent writes an implementation that does not compile",
             context do
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked with a compiler-error reason", context do
        assert context.response["decision"] == "block",
               "compile error must block the stop, got: #{inspect(context.response)}"

        reason = context.response["reason"]

        assert is_binary(reason), "reason must be present, got: #{inspect(reason)}"

        assert reason =~ ~r/compil/i,
               "reason must mention compilation, got:\n#{reason}"

        assert reason =~ "lib/example_context.ex",
               "reason must reference the offending file, got:\n#{reason}"

        {:ok, context}
      end

      then_ "no test or credo output appears in the block reason",
            context do
        reason = context.response["reason"]

        refute reason =~ ~r/\bcredo\b/i,
               "credo must not run when compile errors, got:\n#{reason}"

        refute reason =~ ~r/\bexunit\b/i,
               "exunit must not run when compile errors, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
