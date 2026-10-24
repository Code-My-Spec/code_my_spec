defmodule CodeMySpec.Agents.AClaimFollowsTheDeclaredPrerequisitesTest do
  @moduledoc """
  5a0c4944. `story_promoted` declares `qa_complete` as its prerequisite. The
  offer honoured that (nothing was offered while QA ran), but `start_task`
  checked only that the node itself was open, so an agent that named
  `story_promoted` claimed it while QA was still running; only the
  `evaluate_task` check refused it, afterwards. A claim reads the same
  declaration the offer does, for every story requirement.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.Work
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp claim(ctx, agent, name, story) do
    Slice.attempt(ctx, "start_task", %{
      requirement_name: name,
      entity_type: "story",
      entity_id: to_string(story.number),
      agent_id: agent.id
    })
  end

  describe "QA has not passed" do
    setup ctx do
      ctx =
        ctx
        |> FullSatisfactionFixtures.apply_without_qa_story()
        |> Slice.activate()
        |> Slice.main_copy()

      [coding, _qa] = ctx.team
      %{ctx: ctx, coding: coding}
    end

    test "story_promoted is not offered", %{ctx: ctx, coding: coding} do
      refute "story_promoted" in Enum.map(Work.claimable_work(ctx.scope, coding), & &1.name)
    end

    test "story_promoted is not claimable, and the refusal names qa_complete",
         %{ctx: ctx, coding: coding} do
      assert {true, text} = claim(ctx, coding, "story_promoted", ctx.story)
      assert text =~ "qa_complete"
      assert text =~ "not open yet"
    end
  end

  describe "QA has passed" do
    setup ctx do
      ctx = ctx |> Slice.complete() |> Slice.main_copy()
      [coding, _qa] = ctx.team
      %{ctx: ctx, coding: coding}
    end

    test "story_promoted is claimable", %{ctx: ctx, coding: coding} do
      assert {false, text} = claim(ctx, coding, "story_promoted", ctx.story)
      assert text =~ "passed QA"
    end
  end
end
