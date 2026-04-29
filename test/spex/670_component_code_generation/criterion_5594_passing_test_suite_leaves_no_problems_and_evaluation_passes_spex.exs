defmodule CodeMySpecSpex.Story670.Criterion5594Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5594 — Passing test suite leaves no problems and
  evaluation passes.

  Surface: stop hook drives Validation + TaskEvaluator. With an active
  ComponentCode task and a clean pipeline run (compile clean, exunit
  all-pass), the `exunit_stale` analyzer's run leaves no persisted
  problems on the test file, so `ComponentCode.evaluate/2` returns
  `:valid` and the stop is allowed. This is the "tests run, all
  green" half of the analyzer contract — the failure-path mirror
  lives in criterion 5595.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation" do
    scenario "Passing test suite leaves no problems and evaluation passes" do
      given_ :synced_context_component

      given_ "the agent has signalled session start and started an implementation_file task",
             context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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

      when_ "the stop hook fires after the analyzer ran the test suite to completion",
            context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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
               "passing test suite must leave no problems and allow the stop, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
