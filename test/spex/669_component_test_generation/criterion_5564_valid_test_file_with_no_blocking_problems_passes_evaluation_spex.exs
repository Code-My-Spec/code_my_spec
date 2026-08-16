defmodule CodeMySpecSpex.Story669.Criterion5564Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5564 — Valid test file with no blocking problems passes
  evaluation.

  Surface: stop hook drives Validation + TaskEvaluator. With an active
  ComponentTest task, a written test file, and a clean pipeline run
  (no compile errors, no credo, no failing tests), `ComponentTest.evaluate/2`
  returns `:valid` and the stop is allowed.

  Reuses the `clean` cassette and `pipeline_clean_run` fixtures from
  Story 555.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  @test_path "test/example_context_test.exs"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "Valid test file with no blocking problems passes evaluation" do
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

      given_ "the agent writes a passing test file", context do
        :ok =
          Environments.write_file(
            context.environment,
            @test_path,
            """
            defmodule ExampleContextTest do
              use ExUnit.Case

              test "passes" do
                assert 1 == 1
              end
            end
            """
          )

        {:ok, context}
      end

      when_ "the stop hook fires with a clean pipeline run", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => fixture_path("compile.jsonl"),
                "exunit" => fixture_path("exunit.json")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed", context do
        assert context.response == %{},
               "clean pipeline run on a written test file must allow the stop, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
