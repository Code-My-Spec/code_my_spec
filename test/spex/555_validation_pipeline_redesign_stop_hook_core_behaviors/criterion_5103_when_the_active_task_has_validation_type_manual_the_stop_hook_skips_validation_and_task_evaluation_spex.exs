defmodule CodeMySpecSpex.Story555.Criterion5103Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5103 — When the active task has validation_type: :manual,
  the stop hook skips validation and task evaluation and allows the
  stop.

  StopController's `decide/6` short-circuits via
  `has_active_manual_task?/1` before the pipeline runs. No cassette
  needed — if the short-circuit broke and the pipeline tried to run,
  the test would fail on a missing cassette.

  Real-contract: the `qa_integration_plan` requirement on the project
  is defined with `validation_type: :manual`, so starting a task for
  that requirement via the `start_task` MCP tool creates a task with
  the required shape. The requirement's artifact (a path under
  `.code_my_spec/integrations/`) is NOT provided, but because manual
  tasks short-circuit before task evaluation runs, that absence never
  matters.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Manual-validation task short-circuits the stop hook" do
    scenario "active manual task → allow with no pipeline and no eval" do
      given_ :synced_context_component

      given_ "the agent starts the qa_integration_plan task on the project via the real contract",
             context do
        external_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => external_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "qa_integration_plan",
              entity_type: "project",
              entity_id: to_string(context.scope.active_project_id),
              session_id: external_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, external_id)}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed with the empty signal", context do
        assert context.response == %{},
               "manual-validation short-circuit must produce empty allow, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end
end
