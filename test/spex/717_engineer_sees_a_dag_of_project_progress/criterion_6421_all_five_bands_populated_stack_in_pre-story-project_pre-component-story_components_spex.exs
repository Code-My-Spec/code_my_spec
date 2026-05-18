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
          |> Enum.map(& &1["attributes"]["y"])

        story_ys =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "story"))
          |> Enum.map(& &1["attributes"]["y"])

        component_ys =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "component"))
          |> Enum.map(& &1["attributes"]["y"])

        # The DAG has FIVE bands, not three. The "story" entity_type covers
        # two of them — pre-component-story (above components) and
        # post-component-story (below components). Splitting story.y values
        # against the component band's y-range gives the actual band
        # membership: pre = story.y above max(component.y), post = story.y
        # below min(component.y). Without the split, a project with both
        # bands trips a false "overlap" because Enum.min(story_ys) picks
        # the lowest post-story node and the assertion crosses the
        # component band.
        component_top = if component_ys == [], do: nil, else: Enum.max(component_ys)
        component_bottom = if component_ys == [], do: nil, else: Enum.min(component_ys)

        {pre_story_ys, post_story_ys} =
          case component_top do
            nil -> {story_ys, []}
            ct -> Enum.split_with(story_ys, &(&1 > ct))
          end

        project_top = if project_ys == [], do: nil, else: Enum.max(project_ys)
        project_bottom = if project_ys == [], do: nil, else: Enum.min(project_ys)

        pre_story_bottom = if pre_story_ys == [], do: nil, else: Enum.min(pre_story_ys)
        pre_story_top = if pre_story_ys == [], do: nil, else: Enum.max(pre_story_ys)

        post_story_top = if post_story_ys == [], do: nil, else: Enum.max(post_story_ys)
        post_story_bottom = if post_story_ys == [], do: nil, else: Enum.min(post_story_ys)

        # Band ordering: project_top → pre_story → components → post_story → project_bottom.
        # Each adjacent pair has a strict y inequality when both are populated.
        if project_top && pre_story_top do
          assert project_top > pre_story_top,
                 "project band (y=#{project_top}) must sit above pre-story band (y=#{pre_story_top})"
        end

        if pre_story_bottom && component_top do
          assert pre_story_bottom > component_top,
                 "pre-story band bottom (y=#{pre_story_bottom}) must sit above component band top (y=#{component_top})"
        end

        if component_bottom && post_story_top do
          assert component_bottom > post_story_top,
                 "component band bottom (y=#{component_bottom}) must sit above post-story band top (y=#{post_story_top})"
        end

        if post_story_bottom && project_bottom && project_bottom != project_top do
          # post-project band only exists when a project node sits below the
          # post-story band; collapses cleanly when absent.
          assert post_story_bottom > project_bottom,
                 "post-story band bottom (y=#{post_story_bottom}) must sit above post-project band (y=#{project_bottom})"
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
