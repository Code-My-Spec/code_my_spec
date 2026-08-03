defmodule CodeMySpecSpex.Story704.Criterion6092Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6092 — Engineer sees registered sub-agents on the session
  detail page.

  Covers Rule 3's engineer-facing side: the existing session detail
  LiveView at `/projects/<name>/sessions/<id>` renders a "Registered
  Sub-agents" section listing each registration with assignment status
  (idle or the task they own).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees registered sub-agents on the session detail page" do
    scenario "session detail page renders both idle and assigned sub-agents" do
      given_ :synced_context_component

      given_ "a session with two registered sub-agents (one idle, one assigned)",
             context do
        session_id = "spex-6092-#{System.unique_integer([:positive])}"
        idle_agent = "idle-#{System.unique_integer([:positive])}"
        assigned_agent = "assigned-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        for {agent_id, agent_name} <- [
              {idle_agent, "@idle-agent"},
              {assigned_agent, "@assigned-agent"}
            ] do
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/subagent-start", %{
            "session_id" => session_id,
            "agent_id" => agent_id,
            "agent_name" => agent_name
          })
          |> Phoenix.ConnTest.json_response(200)
        end

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "spec_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id,
              agent_id: assigned_agent
            },
            frame
          )

        # We need the session's DB id (UUID) for the LiveView route
        session = Fixtures.get_session_by_external_id(context.scope, session_id)

        {:ok,
         Map.merge(context, %{
           session_id: session_id,
           session_db_id: session.id,
           idle_agent: idle_agent,
           assigned_agent: assigned_agent
         })}
      end

      when_ "the engineer opens the session detail page", context do
        {:ok, view, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/sessions/#{context.session_db_id}"
          )

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the Registered Sub-agents section renders with both entries", context do
        # Anchor: section heading is present
        assert has_element?(context.view, "[data-test='registered-subagents-heading']"),
               "expected Registered Sub-agents heading to render"

        # Both sub-agent rows are present
        assert has_element?(
                 context.view,
                 "[data-test='subagent-row'][data-agent-id='#{context.idle_agent}']"
               ),
               "expected a row for idle sub-agent #{context.idle_agent}"

        assert has_element?(
                 context.view,
                 "[data-test='subagent-row'][data-agent-id='#{context.assigned_agent}']"
               ),
               "expected a row for assigned sub-agent #{context.assigned_agent}"

        {:ok, context}
      end

      and_ "idle and assigned classifications are visible in the rendered HTML",
           context do
        html = render(context.view)

        idle_line =
          html
          |> String.split("\n")
          |> Enum.find(&String.contains?(&1, context.idle_agent))

        # The idle row's assignment cell contains "idle"
        assert html =~ ~r/data-agent-id="#{Regex.escape(context.idle_agent)}"[\s\S]*?idle/,
               "expected idle classification for #{context.idle_agent} in row context: #{inspect(idle_line)}"

        assert html =~
                 ~r/data-agent-id="#{Regex.escape(context.assigned_agent)}"[\s\S]*?assigned: spec_file/,
               "expected `assigned: spec_file` classification for #{context.assigned_agent}"

        {:ok, context}
      end
    end
  end
end
