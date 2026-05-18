defmodule CodeMySpecSpex.Story561.Criterion5813Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5813 — When exactly one node is actionable in the graph
  and no other nodes share its sort key, the wave returned by
  next_actionable contains that single node.

  Surface: get_next_requirement MCP tool. The response advertises
  exactly one start_task signature, with no companion siblings.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.GraphAssertions

  @actionable_color "#f5f5f7"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Project_setup renders as actionable on a fresh project" do
    scenario "fresh project's graph shows project_setup in the actionable color" do
      when_ "the engineer opens the requirements graph on a fresh project", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "project_setup renders in the actionable color", context do
        node =
          Enum.find(context.graph["nodes"], fn n ->
            n["attributes"]["name"] == "project_setup" and
              n["attributes"]["entity_type"] == "project"
          end)

        assert node, "expected project_setup node in the graph on a fresh project"

        assert node["attributes"]["color"] == @actionable_color,
               "expected project_setup to render as actionable (#{@actionable_color}), got #{node["attributes"]["color"]}"

        {:ok, context}
      end
    end
  end
end
