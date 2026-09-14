defmodule CodeMySpecLocalWeb.StoriesRequirementsControllerTest do
  @moduledoc """
  What the story requirements listing calls "(actionable)".

  The tag was computed as "not satisfied", with no view of edges, so every open
  requirement on a story carried it — including ones sitting behind an
  unsatisfied prerequisite. Todo story 542 read `deploy (actionable)` while its
  `qa_complete` prerequisite was still open.

  `RequirementGraph.next_actionable/1` was always edge-aware, so the real loop
  never offered `deploy` early; only this listing said otherwise. That is what
  makes it worth pinning rather than shrugging at — the harness behaved, and
  the text an agent reads to decide what to do next disagreed with it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{StoriesFixtures, UsersFixtures}
  import Plug.Conn
  import Plug.Test

  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpecLocalWeb.StoriesRequirementsController

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope)
    %{scope: scope, story: story}
  end

  defp show(scope, story) do
    conn(:get, "/api/projects/test/stories/#{story.id}")
    |> assign(:current_scope, scope)
    |> StoriesRequirementsController.show(%{
      "story_id" => to_string(story.id),
      "project_name" => "test"
    })
  end

  defp tagged_actionable(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "(actionable)"))
    |> Enum.map(fn line ->
      line |> String.split("**") |> Enum.at(1)
    end)
    |> MapSet.new()
  end

  describe "GET show" do
    test "only requirements the graph would actually offer are tagged", %{
      scope: scope,
      story: story
    } do
      conn = show(scope, story)
      assert conn.status in [200, nil]

      tagged = tagged_actionable(conn.resp_body)

      really_actionable =
        scope
        |> RequirementGraph.next_actionable()
        |> Enum.filter(&(&1.entity_type == "story" and &1.entity_id == story.id))
        |> MapSet.new(& &1.name)

      assert MapSet.equal?(tagged, really_actionable),
             """
             The listing and the loop have to agree about what can be worked on.

             tagged as actionable: #{inspect(MapSet.to_list(tagged))}
             actually offered:     #{inspect(MapSet.to_list(really_actionable))}

             Extras here are requirements sitting behind an unsatisfied
             prerequisite — the `deploy (actionable)` / `qa_complete` open case
             from Todo story 542.
             """
    end

    test "an unsatisfied requirement behind a prerequisite is not tagged", %{
      scope: scope,
      story: story
    } do
      # The controller serves rows; the write path computes them.
      CodeMySpec.Requirements.recompute(scope)

      conn = show(scope, story)
      body = conn.resp_body

      unsatisfied =
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "- [ ]"))

      blocked = Enum.reject(unsatisfied, &String.contains?(&1, "(actionable)"))

      assert unsatisfied != [], "a fresh story should have open requirements to reason about"

      assert blocked != [],
             """
             A fresh story's requirements form a chain — three amigos before
             specs before QA. If every open one is tagged actionable, the tag
             is just restating "[ ]" and carries no information.

             #{body}
             """
    end
  end
end
