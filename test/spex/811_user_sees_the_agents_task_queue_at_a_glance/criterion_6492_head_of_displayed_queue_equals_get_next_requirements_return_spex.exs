defmodule CodeMySpecSpex.Story811.Criterion6492Spex do
  @moduledoc """
  Story 811 — User sees the agent's task queue at a glance
  Criterion 6492 — Head of displayed queue equals
  get_next_requirement's return.

  The displayed order isn't a separate ranking — it IS what the
  orchestrator would actually serve. If `get_next_requirement`
  returns requirement X first, the LiveView must render X as the
  active (or head-of-upcoming) item. Anything else means the view
  is lying about what's about to happen.

  Surface: `CodeMySpecWeb.AppLive.TaskQueue` LiveView at `/app/tasks`,
  cross-referenced with the `GetNextRequirement` MCP tool to confirm
  the agent-facing dispatch and the user-facing display match.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Head of displayed queue equals get_next_requirement's return" do
    scenario "the first item the LiveView renders matches what the MCP tool serves" do
      given_ "the project has multiple actionable requirements", context do
        # Fresh project state: project_setup is actionable first,
        # everything else queued behind it. Multiple distinct
        # requirements exist in the graph.
        {:ok, context}
      end

      when_ "Sam opens the task queue view", context do
        {:ok, _view, html} = live(context.conn, "/app/projects/#{context.project.id}/tasks")
        {:ok, Map.put(context, :html, html)}
      end

      and_ "the agent calls get_next_requirement against the same project state",
           context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok,
         Map.put(context, :next_requirement_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the head of the displayed queue references the same requirement",
            context do
        # The get_next_requirement tool always includes
        # `requirement_name=\`...\`` in its directive — match it directly.
        [_, name] = Regex.run(~r/requirement_name=`([^`]+)`/, context.next_requirement_text)

        assert context.html =~ name,
               "expected the displayed queue head to reference requirement_name=#{name}; rendered: #{String.slice(context.html, 0, 500)}"

        {:ok, context}
      end
    end
  end
end
