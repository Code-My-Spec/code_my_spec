defmodule CodeMySpecSpex.Story704.Criterion6094Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6094 — TTL-expired registration is absent from both surfaces.

  Covers Rule 3's parity: the engineer's session detail LiveView and
  the `list_session_subagents` MCP tool must agree on what's visible.
  A registration whose `last_heartbeat_at` is older than TTL appears
  on NEITHER surface.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "TTL-expired registration is absent from both surfaces", criterion: 439 do
    scenario "stale registration is filtered out of LiveView AND MCP tool response" do
      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "a session with one registration whose heartbeat is past the TTL",
             context do
        session_id = "spex-6094-#{System.unique_integer([:positive])}"
        agent_id = "stale-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        {:ok, _session} =
          Fixtures.register_subagent_with_heartbeat(context.scope, session_id, %{
            agent_id: agent_id,
            agent_name: "@stale",
            last_heartbeat_at:
              DateTime.utc_now()
              |> DateTime.add(-30 * 60, :second)
              |> DateTime.truncate(:second)
          })

        session = Fixtures.get_session_by_external_id(context.scope, session_id)

        {:ok,
         Map.merge(context, %{
           session_id: session_id,
           session_db_id: session.id,
           agent_id: agent_id
         })}
      end

      when_ "the engineer opens the session page AND the agent calls list_session_subagents",
            context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/sessions/#{context.session_db_id}"
          )

        frame = %Frame{assigns: %{current_scope: context.scope}}

        mcp_response =
          ToolLibrary.run(
            "list_session_subagents",
            %{session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok,
         Map.merge(context, %{
           view: view,
           mcp_text: TaskResponseHelpers.response_text(mcp_response)
         })}
      end

      then_ "neither the LiveView nor the MCP response includes the stale registration",
            context do
        refute has_element?(
                 context.view,
                 "[data-test='subagent-row'][data-agent-id='#{context.agent_id}']"
               ),
               "expected LiveView to omit stale registration #{context.agent_id}"

        refute context.mcp_text =~ context.agent_id,
               "expected MCP response to omit stale registration #{context.agent_id}, got:\n#{context.mcp_text}"

        {:ok, context}
      end

      and_ "the LiveView still renders its Registered Sub-agents heading (anchor)",
           context do
        assert has_element?(context.view, "[data-test='registered-subagents-heading']"),
               "expected the section heading to render even with all entries pruned"

        {:ok, context}
      end
    end
  end
end
