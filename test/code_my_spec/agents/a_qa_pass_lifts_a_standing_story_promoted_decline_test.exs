defmodule CodeMySpec.Agents.AQaPassLiftsAStandingStoryPromotedDeclineTest do
  @moduledoc """
  90beae27, criterion 2055: an agent's decline, with its reason, stops an
  offer until what it offers changes. Story 1004's coding agent declined
  `story:1004:story_promoted` while QA was still running -- a true reason at
  that moment -- and the decline held the subject back from every later
  offer, unchanged, for about five hours after qa_complete actually became
  satisfied. `Offers.standing/1` keyed the hold on `agent_id` + `subject_key`
  alone, with no notion of the state the agent had actually refused, so
  nothing but a direct `start_task` from main ever lifted it.

  Fix: the `[:code_my_spec, :qa, :story_passed]` event -- fired once per
  passing, non-stale QA attempt, already handled for the "team free" case --
  now also supersedes any standing `story_promoted` decline for the story's
  own coding agent(s), via the new `Offers.lift_decline/2`.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Agents.Events
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.DevicesFixtures
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp decline_story_promoted(story, agent) do
    key = "story:#{story.number}:story_promoted"

    offer =
      Offers.record_declined(
        agent,
        :work,
        {"requirement", key},
        "no QA attempt has passed at that commit yet"
      )

    refute is_nil(offer), "the premise failed: the decline itself was not recorded"
    key
  end

  defp staffed_story(ctx) do
    {:ok, team} =
      WorkingCopies.issue(ctx.scope, nil,
        label: "team",
        device: DevicesFixtures.device_fixture(ctx.scope)
      )

    story = story_fixture(ctx.scope, %{ready_for_dev: true})
    {:ok, story} = Stories.update_story(ctx.scope, story, %{working_copy_id: team.id})

    team_scope = %{ctx.scope | active_working_copy_id: team.id}
    coding = CodeMySpecSpex.Fixtures.running_agent(team_scope, role: "coding")

    %{story: story, coding: coding}
  end

  defp pass_qa(scope, story) do
    Events.handle_event(
      [:code_my_spec, :qa, :story_passed],
      %{},
      %{scope: scope, story_id: story.id},
      nil
    )
  end

  test "a decline recorded before QA passed does not outlive the pass", ctx do
    %{story: story, coding: coding} = staffed_story(ctx)
    key = decline_story_promoted(story, coding)

    assert match?(%{held?: true, declined?: true}, Offers.standing(coding.id)[key]),
           "the premise failed: the decline is not standing"

    pass_qa(ctx.scope, story)

    refute match?(%{held?: true}, Offers.standing(coding.id)[key]),
           """
           qa_complete passing changed what story_promoted offers, but the decline
           made before the pass still held it back afterward.
           """
  end

  test "a decline on a different story's story_promoted is untouched", ctx do
    %{story: story, coding: coding} = staffed_story(ctx)
    key = decline_story_promoted(story, coding)

    %{story: other_story} = staffed_story(ctx)
    pass_qa(ctx.scope, other_story)

    assert match?(%{held?: true}, Offers.standing(coding.id)[key]),
           "a different story's QA pass lifted this story's standing decline"
  end
end
