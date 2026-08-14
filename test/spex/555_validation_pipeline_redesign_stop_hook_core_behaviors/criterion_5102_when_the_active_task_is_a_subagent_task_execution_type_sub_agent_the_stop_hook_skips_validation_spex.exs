defmodule CodeMySpecSpex.Story555.Criterion5102Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5102 — When the active task is owned by a sub-agent (R5a:
  alive + assigned + working), the stop hook short-circuits and allows
  the stop immediately — the main agent is idle by design while the
  sub-agent works.

  ## Surface

  Sub-agent registration goes through the production webhook
  `POST /api/hooks/subagent-start`. The task is then claimed at
  creation by passing `agent_id` to the real `start_task` MCP tool —
  the same path a sub-agent takes when it picks up a task in
  production. With the runtime claim in place, `has_active_subagent_task?/1`
  short-circuits the decide/6 cascade before validation runs.

  Pre-704 wording of this criterion was based on `execution_type:
  :sub_agent` alone. Story 704 refined R5a to runtime-claim semantics
  (agent_id != nil); the test now establishes both signals.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sub-agent-owned task short-circuits the stop hook" do
    scenario "active task claimed by a registered sub-agent → allow with no pipeline" do
      given_ :synced_liveview_component

      given_ "a sub-agent has registered on a session and claimed a test_spec_alignment task",
             context do
        external_id = "spex-#{System.unique_integer([:positive])}"
        agent_id = "spex-5102-subagent-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => external_id})
        |> Phoenix.ConnTest.json_response(200)

        registration =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/hooks/subagent-start", %{
            "session_id" => external_id,
            "agent_id" => agent_id,
            "agent_name" => "codemyspec:code-writer"
          })
          |> Phoenix.ConnTest.json_response(200)

        # Without this guard, a silent registration failure (e.g. session
        # mismatch) would leave the scenario testing the wrong baseline —
        # the task would not actually be sub-agent-claimed.
        assert registration["agent_id"] == agent_id,
               "expected registration to echo agent_id, got: #{inspect(registration)}"

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "test_spec_alignment",
              entity_type: "component",
              entity_id: to_string(context.liveview_component.id),
              session_id: external_id,
              agent_id: agent_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, external_id)}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
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
