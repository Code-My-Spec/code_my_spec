defmodule CodeMySpec.Requirements.Tools.ListRequirementsExplainsWhyAStoryReadsEmptyTest do
  @moduledoc """
  51c8e8a7: `ShowStoryRequirements` already carries two legitimate reasons a
  released story's requirements read empty -- `unreleased_note/1` (never
  released for development) and `reconciling_note/1` (a manifest is still
  landing, `knowledge/requirements_graph`, "Writers and readers" -- 7b8a61d2).
  `ListRequirements` filters by the same `story_number` but carried neither,
  so the identical empty read here had nothing to say about why.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Files.ReconcileRegistry
  alias CodeMySpec.Stories
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies

  test "an unreleased story says it has not been released, not that it is satisfied" do
    scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())
    story = story_fixture(scope, %{ready_for_dev: false})

    frame = %Frame{assigns: %{current_scope: scope}}
    params = %{entity_type: "story", entity_id: to_string(story.number)}

    response =
      ToolLibrary.run(
        "list_requirements",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response)
    {:ok, content} = response

    assert content =~ "has not been released for development"
  end

  test "a released story caught mid-reconcile at its own copy says so, not nothing" do
    scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())

    {:ok, team} =
      WorkingCopies.issue(scope, nil,
        label: "team",
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    story = story_fixture(scope, %{ready_for_dev: true})
    {:ok, story} = Stories.update_story(scope, story, %{working_copy_id: team.id})

    team_scope = %{scope | active_working_copy_id: team.id}
    {{_nodes, _edges}, _actionable, _at} = CodeMySpec.Requirements.recompute(team_scope)

    # The test process registers itself as the in-flight reconcile for
    # `team.id` -- `ReconcileRegistry.mark/2` registers whichever process
    # calls it, and the entry lives exactly as long as that process does.
    :ok = ReconcileRegistry.mark(team.id, 7)

    frame = %Frame{assigns: %{current_scope: scope}}
    params = %{entity_type: "story", entity_id: to_string(story.number)}

    response =
      ToolLibrary.run(
        "list_requirements",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response)
    {:ok, content} = response

    assert content =~ "Reconciling 7 observations",
           "a read caught mid-reconcile at the story's own copy must say so, not read as " <>
             "ordinary satisfied-or-not rows"
  end
end
