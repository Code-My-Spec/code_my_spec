defmodule CodeMySpec.Agents.TheTeamFinishesAStoryTogetherTest do
  @moduledoc """
  a31f1cd6 step 3. The team moves on only when its story is complete for all
  of it, and then it moves together: one agent's part finishing advances
  nobody, and a finished story takes the whole team onto the next eligible one
  without anyone selecting it.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Repo
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    coding = CodeMySpecSpex.Fixtures.running_agent(ctx.scope, role: "coding")
    qa = CodeMySpecSpex.Fixtures.running_agent(ctx.scope, role: "qa")
    Map.merge(ctx, %{coding: coding, qa: qa})
  end

  defp held(agent), do: Repo.get!(CodeMySpec.Agents.Agent, agent.id).story_id

  test "coding's part being done does not move the team off the story", ctx do
    ctx =
      ctx
      |> CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story()
      |> Slice.activate()
      |> Slice.waiting()

    coding = Slice.next(ctx, %{agent_id: ctx.coding.id})

    assert coding =~ "# Story #{ctx.story.number}:"
    refute Slice.offered?(coding, ctx.waiting.id)
    assert Slice.next(ctx, %{agent_id: ctx.qa.id}) =~ "qa_complete"
    assert held(ctx.coding) == ctx.story.id
    assert held(ctx.qa) == ctx.story.id
  end

  test "a finished story moves the whole team onto the next eligible story", ctx do
    ctx = ctx |> Slice.complete() |> Slice.land() |> Slice.waiting()

    answer = Slice.next(ctx, %{agent_id: ctx.coding.id})

    assert answer =~ "# Story #{ctx.waiting.number}:"
    assert held(ctx.coding) == ctx.waiting.id
    assert held(ctx.qa) == ctx.waiting.id, "the teammate moved with it"
    assert Slice.next(ctx, %{agent_id: ctx.qa.id}) =~ "# Story #{ctx.waiting.number}:"
  end

  test "with nothing eligible the team stays on its finished story", ctx do
    ctx = ctx |> Slice.complete() |> Slice.land()

    Slice.assert_active(Slice.next(ctx, %{agent_id: ctx.coding.id}), ctx, "complete")
    assert held(ctx.qa) == ctx.story.id
  end

  test "a session reading a finished story does not move the team", ctx do
    ctx = ctx |> Slice.complete() |> Slice.land() |> Slice.waiting()

    Slice.assert_active(Slice.next(ctx), ctx, "complete")
    assert held(ctx.coding) == ctx.story.id
  end
end
