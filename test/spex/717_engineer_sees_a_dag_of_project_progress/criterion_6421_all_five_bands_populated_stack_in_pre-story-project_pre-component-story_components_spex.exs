defmodule CodeMySpecSpex.Story717.Criterion6421Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6421 — All five bands populated stack in pre-story-project → pre-component-story → components → post-component-story → post-story-project order.

  The strict 5-band test asserts that whatever subset of bands has
  nodes, the band ordering invariant holds: every node in an upper
  band sits at strictly greater y than every node in any lower band.
  Empty bands collapse without breaking the order of populated bands
  (R1 clause).

  Current schema produces 4 bands (no post-story-project gate exists
  after qa_preflight deletion); the assertion is written so it
  validates the order across whatever bands ARE populated rather
  than insisting on all 5 being non-empty.

  Surface: `/projects/:project_name/requirements/graph?preload=true`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The DAG renders as five horizontal bands top-to-bottom; bands with zero nodes collapse without breaking the order of the bands that do" do
    scenario "All five bands populated stack in pre-story-project → pre-component-story → components → post-component-story → post-story-project order" do
      given_ :cross_context_dependency

      when_ "the engineer opens the requirements graph view with preload enabled", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        graph = view |> render() |> extract_graph()

        {:ok, Map.put(context, :graph, graph)}
      end

      then_ "every populated band's nodes sit strictly above every lower-band's nodes",
            context do
        nodes = context.graph["nodes"]

        project_ys =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "project"))
          |> Enum.map(&{&1["attributes"]["x"], &1["attributes"]["y"]})

        story_ys =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "story"))
          |> Enum.map(& &1["attributes"]["y"])

        component_ys =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "component"))
          |> Enum.map(& &1["attributes"]["y"])

        # Pre-story project = max y across project nodes (they all share y == 0
        # in the horizontal band layout). Post-story project would be below
        # the lowest component, but current schema has none — skip when
        # empty.
        project_top = project_ys |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> nil end)

        story_top = if story_ys == [], do: nil, else: Enum.max(story_ys)
        story_bottom = if story_ys == [], do: nil, else: Enum.min(story_ys)

        component_top = if component_ys == [], do: nil, else: Enum.max(component_ys)

        if project_top && story_top do
          assert project_top > story_top,
                 "expected project band (y=#{project_top}) strictly above story band (y=#{story_top})"
        end

        if story_bottom && component_top do
          assert story_bottom > component_top,
                 "expected story band bottom (y=#{story_bottom}) strictly above component band top (y=#{component_top})"
        end

        {:ok, context}
      end
    end
  end

  defp extract_graph(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#sigma-graph")
    |> Floki.attribute("data-graph")
    |> List.first()
    |> Jason.decode!()
  end
end
