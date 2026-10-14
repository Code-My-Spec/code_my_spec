defmodule CodeMySpec.Agents.TheTeamFinishesAStoryTogetherTest do
  @moduledoc """
  a31f1cd6 step 3. The team moves on only when its story is complete for all
  of it, and then it moves together: one agent's part finishing advances
  nobody.

  John, 2026-10-07 retired the other half of that — the automatic move. A
  finished story does not take the team anywhere; a landing tells main the team
  is free and main assigns the next story with `set_active_story` (criteria
  2064/2065). So what is left here is the "moves together, or not at all"
  property, asserted from the not-at-all side: nothing a teammate reads moves
  the team, complete or landed.

  The `held` assertions are the point rather than the rendered answer alone.
  The answer could name the right story while the rows said otherwise, and the
  incident f0c18598 was exactly that: `set_active_story` returned success four
  times and the team's rows were moved within the minute anyway.
  """

  # Sync: failed under concurrency in the 2026-10-14 async sweep.
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

  test "a finished story does not move the team onto the next eligible story", ctx do
    ctx = ctx |> Slice.complete() |> Slice.land() |> Slice.waiting()

    # John, 2026-10-07: the automatic rebinding is retired. A landed story is
    # finished, and finishing is not a move — it tells main the team is free so
    # main can assign the next story with `set_active_story` (criterion 2064).
    # This test asserted the opposite until then, and `208fba1c`/`f0c18598` are
    # why: a team that walked itself off a story could not be held on it.
    answer = Slice.next(ctx, %{agent_id: ctx.coding.id})

    refute answer =~ "# Story #{ctx.waiting.number}:",
           "a finished story moved the whole team on its own. The move is always an " <>
             "agent's act. Got:\n#{answer}"

    assert held(ctx.coding) == ctx.story.id
    assert held(ctx.qa) == ctx.story.id, "the teammate moved with it"
    refute Slice.next(ctx, %{agent_id: ctx.qa.id}) =~ "# Story #{ctx.waiting.number}:"
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
