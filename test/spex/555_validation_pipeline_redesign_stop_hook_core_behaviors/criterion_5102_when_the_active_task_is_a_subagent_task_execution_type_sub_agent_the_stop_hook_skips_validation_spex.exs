defmodule CodeMySpecSpex.Story555.Criterion5102Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5102 — When the active task is a subagent task
  (execution_type: :sub_agent), the stop hook skips validation
  entirely and allows the stop immediately.

  StopController's `decide/6` short-circuits via
  `has_active_subagent_task?/1` before validation runs. No pipeline,
  no cassette — a missing one would fail if the short-circuit broke.

  Real-contract: `:synced_liveview_component` produces a liveview
  component so the liveview_graph applies. Starting a task on the
  `test_spec_alignment` requirement (node_scope :self, execution_type
  :sub_agent) via the real `start_task` MCP tool yields a task with
  the required shape.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Subagent task short-circuits the stop hook" do
    scenario "active subagent task → allow with no pipeline" do
      given_ :synced_liveview_component

      given_ "the agent starts a test_spec_alignment subagent task on the liveview component",
             context do
        external_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => external_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "test_spec_alignment",
              entity_type: "component",
              entity_id: to_string(context.liveview_component.id),
              session_id: external_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, external_id)}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed with the empty signal", context do
        assert context.response == %{},
               "subagent short-circuit must produce empty allow, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end
end
