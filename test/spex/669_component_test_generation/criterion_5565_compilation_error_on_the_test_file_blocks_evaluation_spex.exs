defmodule CodeMySpecSpex.Story669.Criterion5565Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5565 — Compilation error on the test file blocks evaluation.

  Surface: stop hook drives Validation + TaskEvaluator. With an active
  ComponentTest task and a compile-error JSONL fixture, the pipeline
  short-circuits at compile and persists the error problem. The stop
  hook blocks with the compile diagnostic in the reason.

  Reuses the `pipeline_compile_error` cassette (single `mix compile`
  command, exit_code 1) from Story 555. The JSONL fixture asserts the
  error lives on the test file path so the agent's feedback ties back
  to the file the ComponentTest task is working on.
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

  spex "Component Test Generation" do
    scenario "Compilation error on the test file blocks evaluation" do
      given_ :synced_context_component

      given_ "the agent has signalled session start and started a test_file task", context do
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
              requirement_name: "test_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "the agent writes a test file with a syntax error", context do
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

      when_ "the stop hook fires", context do
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

      then_ "the stop is blocked with the compile error in the reason", context do
        assert context.response["decision"] == "block",
               "compile error on the test file must block, got: #{inspect(context.response)}"

        reason = context.response["reason"]
        assert is_binary(reason)

        assert reason =~ ~r/compil/i,
               "reason must mention compilation, got:\n#{reason}"

        assert reason =~ @test_path,
               "reason must reference the offending test file, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
