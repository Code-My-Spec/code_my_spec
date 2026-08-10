defmodule CodeMySpecSpex.Story561.Criterion5813Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5813 — When exactly one node is actionable in the graph
  and no other nodes share its sort key, the wave returned by
  next_actionable contains that single node.

  Surface: the requirements graph. A fresh project has exactly one node with
  no prerequisites, and it renders in the actionable color.

  That node used to be `project_setup`. Setup is no longer a requirement —
  `cms new` covers it and the mainline exits the generator with it complete,
  so a generated project has nothing to do there, and brownfield onboarding
  is entered deliberately at /app/projects/:id/setup instead. `personas_
  complete` is the root of the graph now (`prerequisites: []`), so it is what
  a fresh project offers.

  The criterion is about the shape of the wave, not about which requirement
  happens to sit at the root, so only the name moved.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.GraphAssertions

  @actionable_color "#f5f5f7"
  @root "personas_complete"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The graph root renders as actionable on a fresh project" do
    scenario "fresh project's graph shows its single root in the actionable color" do
      when_ "the engineer opens the requirements graph on a fresh project", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "#{@root} renders in the actionable color", context do
        node =
          Enum.find(context.graph["nodes"], fn n ->
            n["attributes"]["name"] == @root
          end)

        assert node, "expected the #{@root} node in the graph on a fresh project"

        assert node["attributes"]["color"] == @actionable_color,
               "expected #{@root} to render as actionable (#{@actionable_color}), got #{node["attributes"]["color"]}"

        {:ok, context}
      end

      then_ "it is the only actionable node", context do
        actionable =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["color"] == @actionable_color end)
          |> Enum.map(fn n -> n["attributes"]["name"] end)

        assert actionable == [@root],
               "a one-element wave means exactly one actionable node; got: #{inspect(actionable)}"

        {:ok, context}
      end
    end
  end
end
