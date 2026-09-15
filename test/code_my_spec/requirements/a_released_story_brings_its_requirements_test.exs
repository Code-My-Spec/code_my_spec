defmodule CodeMySpec.Requirements.AReleasedStoryBringsItsRequirementsTest do
  @moduledoc """
  Releasing a story has to put its requirements in the graph, on the read that
  follows.

  Criterion 7942 asserts this through the stories LiveView and is red on this
  branch and on no other working copy, which makes it this branch's regression
  rather than an inherited one. This is the same sequence without the LiveView,
  so the answer says whether the fault is in the graph or in the surface.
  """

  use CodeMySpecSpex.Case, async: false

  # `/app/projects/.../stories` is a cloud-app route; the case's default
  # endpoint is the local app, where `live/2` answers 404.
  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Stories

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp story_nodes(scope, story_id) do
    {nodes, _computed_at} = Requirements.cached_all(scope)
    Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story_id))
  end

  test "a story released after the graph was computed appears on the next read", ctx do
    # Parked, so it is deliberately absent from the graph to begin with.
    created = create_story(ctx.scope, title: "Players have a discrete age", description: "x")
    story = Stories.get_story!(ctx.scope, created.id)
    {:ok, story} = Stories.update_story(ctx.scope, story, %{ready_for_dev: false})

    :ok = GraphWatcher.settle(ctx.scope)
    assert story_nodes(ctx.scope, story.id) == [], "a parked story should produce no nodes"

    {:ok, story} = Stories.update_story(ctx.scope, story, %{ready_for_dev: true})

    nodes = story_nodes(ctx.scope, story.id)

    assert Enum.any?(nodes, &(&1.name == "component_linked")),
           """
           A released story produced no requirements on the read that followed.

           `update_story/3` announces through `Stories.broadcast/2`, and the read
           settles before it serves — so either the announcement did not reach
           the watcher, the pass did not include this story, or the pass computed
           a vantage this reader does not read from.

           nodes: #{inspect(Enum.map(nodes, & &1.name))}
           """
  end

  # The same claim through the surface criterion 7942 actually drives. If this
  # fails while the one above passes, the graph is fine and the fault is in what
  # the LiveView writes or the scope it writes from.
  test "a story released through the stories LiveView appears on the next read", ctx do
    # Created through the same MCP tool criterion 7942 uses, which is the last
    # difference between that spex and the passing case above.
    frame = %Frame{assigns: %{current_scope: ctx.scope}}

    {:reply, response, _frame} =
      CreateStory.execute(
        %{title: "Released from the page", description: "created via the tool"},
        frame
      )

    refute response.isError, inspect(response)

    story =
      ctx.scope
      |> Stories.list_stories()
      |> Enum.find(&(&1.title == "Released from the page"))

    :ok = GraphWatcher.settle(ctx.scope)
    assert story_nodes(ctx.scope, story.id) == [], "a parked story should produce no nodes"

    {:ok, index_live, _html} =
      live(ctx.conn, "/app/projects/#{ctx.scope.active_project_id}/stories")

    index_live
    |> element("[data-test='toggle-story-ready'][phx-value-id='#{story.id}']")
    |> render_click()

    nodes = story_nodes(ctx.scope, story.id)

    assert Enum.any?(nodes, &(&1.name == "component_linked")),
           """
           Released through the LiveView, the story produced no requirements —
           while releasing it through `Stories.update_story/3` does.

           nodes: #{inspect(Enum.map(nodes, & &1.name))}
           """
  end
end
