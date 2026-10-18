defmodule CodeMySpec.Requirements.Tools.ListRequirementsReadsAQueriedStorysOwnCopyTest do
  @moduledoc """
  f66cc07a: `ListRequirements` was the sibling `ShowStoryRequirements` was
  fixed alongside (d4d04dd04, `a_story_reads_at_its_own_copy_test.exs`) but
  never itself fixed -- filtering by one story read that story through the
  CALLER's own active copy, not the copy the story is actually assigned to.

  Same fixture shape as that test: a story assigned to a second working
  copy, recomputed only there, then queried from a scope whose own active
  copy is the project's default (and has no node for this story at all,
  since a story's copy assignment excludes it from every other copy's own
  graph -- `Preloader.assigned_here_or_unassigned/2`).
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpec.Requirements
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  test "filtering by a story assigned to another copy reads that copy, not the caller's" do
    scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())

    {:ok, team} =
      WorkingCopies.issue(scope, nil,
        label: "team",
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    story = story_fixture(scope, %{ready_for_dev: true})
    {:ok, story} = Stories.update_story(scope, story, %{working_copy_id: team.id})

    team_scope = %{scope | active_working_copy_id: team.id}
    {{nodes, _edges}, _actionable, _at} = Requirements.recompute(team_scope)
    assert Enum.any?(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))

    frame = %Frame{assigns: %{current_scope: scope}}

    # The shape `StoryRefs.normalize_args/2` produces for a caller's
    # `story_number` before `execute/2` ever sees it -- exercised directly
    # here since that normalization runs in the request pipeline, not when
    # calling `execute/2` straight from a test.
    params = %{entity_type: "story", entity_id: to_string(story.number)}

    assert {:ok, rows} =
             ToolLibrary.data(
               "list_requirements",
               params,
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    refute rows == [],
           "read at the caller's own copy instead of the story's -- got no rows for a story " <>
             "that has 8 of them on its own copy"

    assert Enum.all?(rows, &(&1["entity_id"] == to_string(story.number)))
  end
end
