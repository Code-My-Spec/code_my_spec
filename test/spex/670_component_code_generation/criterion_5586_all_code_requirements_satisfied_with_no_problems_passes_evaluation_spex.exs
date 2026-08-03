defmodule CodeMySpecSpex.Story670.Criterion5586Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5586 — All code requirements satisfied with no problems
  passes evaluation.

  Surface: stop hook drives Validation + TaskEvaluator. With an active
  ComponentCode task on a synced context Component (spec + impl already
  on disk via `:synced_context_component`) and a clean pipeline run
  (no compile errors, no failing tests), `ComponentCode.evaluate/2`
  returns `:valid` and the stop is allowed.
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
    scenario "All code requirements satisfied with no problems passes evaluation" do
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

      when_ "the stop hook fires with a clean pipeline run", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
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
               "clean pipeline run with satisfied implementation_file must allow the stop, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
