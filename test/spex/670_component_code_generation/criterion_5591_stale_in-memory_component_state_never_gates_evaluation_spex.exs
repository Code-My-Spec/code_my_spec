defmodule CodeMySpecSpex.Story670.Criterion5591Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5591 — Stale in-memory component state never gates
  evaluation.

  Surface: stop hook drives Validation + TaskEvaluator. The
  observable contract for "evaluate/2 reloads from the database
  before checking" is the inverse of 5590: a problem persisted on
  the *test* file between command and evaluate must surface in the
  feedback even though command/2's component snapshot had no
  problems on it. If the evaluator ever held the in-memory snapshot
  and skipped the reload, the test-file problem would be invisible
  and the gate would let the stop through.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  @test_path "test/example_context_test.exs"
  @fixture_dir "test/fixtures/validation/component_test_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation" do
    scenario "Stale in-memory component state never gates evaluation" do
      given_ :synced_context_component

      given_ "the agent has signalled session start and command/2 fired with a clean component",
             context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "between command and evaluate, the agent writes a malformed test file", context do
        :ok =
          Environments.write_file(
            context.environment,
            @test_path,
            """
            defmodule ExampleContextTest do
              use ExUnit.Case
            # missing `end`
            """
          )

        {:ok, context}
      end

      when_ "the stop hook fires — the analyzer persists a test-file problem after command",
            context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the freshly-persisted test-file problem reaches the blocking feedback", context do
        assert context.response["decision"] == "block",
               "expected the analyzer-written test-file problem to block the stop, got: #{inspect(context.response)}"

        reason = context.response["reason"]
        assert is_binary(reason)

        assert reason =~ @test_path,
               "stale in-memory state would have hidden this problem — the reload must surface it, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
