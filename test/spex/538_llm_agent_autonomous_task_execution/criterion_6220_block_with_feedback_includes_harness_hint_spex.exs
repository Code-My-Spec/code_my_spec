defmodule CodeMySpecSpex.Story538.Criterion6220Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 6220 — Block-with-feedback responses include a one-line
  harness-reporting hint pointing the agent at `create_issue` with
  `scope: framework`.

  Covers R9 (harness-reporting affordance on block-with-feedback):
  whenever the stop hook blocks with a validation/evaluation reason
  (the `block_with_reason/2` path), the response carries a trailing
  affordance so the agent is reminded the friction may belong to the
  harness rather than the task — and how to report it.

  The block-with-feedback path is exercised here via a compile-error
  pipeline run (the same cassette pattern 555/5099 uses), since the
  footer attaches to the response regardless of which `{:error, _}`
  source triggered the block.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Block-with-feedback responses include an R9 harness-reporting hint" do
    scenario "compile-error block reason carries the create_issue(scope: framework) affordance" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the agent writes an implementation that does not compile", context do
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked", context do
        assert context.response["decision"] == "block",
               "compile error must block the stop, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the block reason carries an R9 harness-reporting hint", context do
        reason = context.response["reason"]

        assert is_binary(reason), "reason must be present, got: #{inspect(reason)}"

        assert reason =~ ~r/create_issue/i,
               "expected the reason to name create_issue, got:\n#{reason}"

        assert reason =~ ~r/scope:\s*framework/i,
               "expected the reason to point at scope: framework, got:\n#{reason}"

        assert reason =~ ~r/harness/i,
               "expected the reason to name harness friction, got:\n#{reason}"

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
