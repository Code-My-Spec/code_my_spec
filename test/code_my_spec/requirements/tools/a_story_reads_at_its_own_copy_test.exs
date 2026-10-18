defmodule CodeMySpec.Requirements.Tools.AStoryReadsAtItsOwnCopyTest do
  @moduledoc """
  A story's requirements are read at the copy it is assigned to.

  They are computed there, so main asking from the main copy read story 1092
  as 0/0 while team 2's copy held 5/8 (2026-10-12), and main managed the story
  on its agents' word.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Requirements.Tools.ShowStoryRequirements
  alias CodeMySpec.Requirements
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  test "a story assigned to another copy shows that copy's requirements" do
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

    response =
      ToolLibrary.run(
        "show_story_requirements",
        %{story_number: story.number},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    text = elem(response, 1)
    refute text =~ "0/0 satisfied", "read at the caller's copy instead of the story's:\n#{text}"
    assert text =~ ~r/\*\*Requirements:\*\*\s+\d+\/[1-9]\d*\s+satisfied/
  end
end
