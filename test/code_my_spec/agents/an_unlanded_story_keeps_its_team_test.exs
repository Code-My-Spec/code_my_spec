defmodule CodeMySpec.Agents.AnUnlandedStoryKeepsItsTeamTest do
  @moduledoc """
  Issue f0c18598. A team's active story stays until it *lands* (John,
  2026-10-06) — until it is promoted, not until it merely reads complete.

  The incident's story 1052 was complete for the whole team and not yet
  promoted: `qa_complete` read satisfied (a stale pass), nothing was
  actionable for either role, and `story_promoted` was unmet. Issue f0c18598
  is what that momentary completeness cost when it was taken for a finish:
  the team was pulled onto the epic's next story, `set_active_story` stopped
  sticking, and the QA that was owed never got the story.

  So the epic pull binds the team to the next story only when the active one
  has landed, never because it reads complete first.

  John, 2026-10-07: the rebinding is retired entirely. A landing does not pull
  the team anywhere either — it tells main the team is free, and main assigns
  the next story with `set_active_story`. So this file's four scenarios are the
  same assertion from both sides: no read moves the team, landed or not. The
  gate f0c18598 asked for (landed, not merely complete) survives inside
  `Assignment.advance/4`, which an explicit assignment still reaches.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Agents
  alias CodeMySpec.Qa.Verdict
  alias CodeMySpec.Repo
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    coding = CodeMySpecSpex.Fixtures.running_agent(ctx.scope, role: "coding")
    qa = CodeMySpecSpex.Fixtures.running_agent(ctx.scope, role: "qa")
    Map.merge(ctx, %{coding: coding, qa: qa})
  end

  defp held(agent), do: Repo.get!(Agents.Agent, agent.id).story_id

  # The incident's own state (issue f0c18598): the story is *complete* for the
  # whole team — QA has passed it, so `qa_complete` reads satisfied and no work
  # is actionable for anyone — and it has not *landed*, because nothing has
  # promoted it. That is the state team 1 was pulled off 1052 from, and the
  # distinction the fix turns on: complete is read from the graph, landed is
  # read from `stories.promoted_version`.
  #
  # `Slice.waiting` puts a second, ready story beside the team's own, which is
  # the epic's next story as far as the pull is concerned: whether it is a
  # member of a named epic or simply the copy's other ready story, it is the
  # one the team must not be moved onto while its own story has not landed.
  defp unlanded(ctx) do
    ctx = ctx |> Slice.staff() |> Slice.complete() |> Slice.waiting()
    {:ok, _} = CodeMySpecSpex.Fixtures.passed_qa_attempt(ctx.scope, story_id: ctx.story.id)
    ctx
  end

  test "a certified story with no promotion stamp keeps its team", ctx do
    ctx = unlanded(ctx)

    story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)

    assert story.promoted_version == nil,
           "the premise failed: this story was promoted, so it has landed"

    assert Verdict.complete?(ctx.scope, ctx.story.id),
           "the premise failed: QA has not passed this story, so it does not read complete"

    assert CodeMySpec.Requirements.story_execution(
             ctx.scope,
             :qa,
             nil,
             fn _ -> false end,
             {:bound, ctx.story.id, nil}
           ).status ==
             :complete,
           "the premise failed: the story does not read complete for the team, so the pull would not fire"

    answer = Slice.next(ctx, %{agent_id: ctx.coding.id})

    assert answer =~ "# Story #{ctx.story.number}:",
           "the team was taken off its certified, unlanded story. Got:\n#{answer}"

    refute answer =~ "# Story #{ctx.waiting.number}:"
    assert held(ctx.coding) == ctx.story.id
    assert held(ctx.qa) == ctx.story.id, "the teammate was pulled with it"
  end

  test "and QA's own turn does not move it either", ctx do
    ctx = unlanded(ctx)

    assert Slice.next(ctx, %{agent_id: ctx.qa.id}) =~ "# Story #{ctx.story.number}:"
    assert held(ctx.coding) == ctx.story.id
    assert held(ctx.qa) == ctx.story.id, "QA's read pulled the team onto another story"
  end

  test "set_active_story sticks while the story has not landed", ctx do
    ctx = unlanded(ctx)

    Slice.call(ctx, CodeMySpec.McpServers.Stories.Tools.SetActiveStory, %{
      story_number: ctx.story.number
    })

    assert held(ctx.coding) == ctx.story.id
    assert held(ctx.qa) == ctx.story.id

    # And still holds after a teammate asks for work, which is when the pull
    # landed in the incident.
    Slice.next(ctx, %{agent_id: ctx.coding.id})
    assert held(ctx.coding) == ctx.story.id
    assert held(ctx.qa) == ctx.story.id
  end

  test "and a landed story does not move the team either", ctx do
    ctx = unlanded(ctx)

    story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
    {:ok, story} = CodeMySpec.Stories.mark_story_promoted(ctx.scope, story, "2.0.44")
    assert story.promoted_version == "2.0.44"

    # Landing is the other half of f0c18598's fix and the whole of John's
    # 2026-10-07 decision: a landing tells main the team is free
    # (`Assignment.notify_team_free/3`) and main assigns the next story with
    # `set_active_story`. Nothing moves the team as a side effect of reading.
    # Criterion 2064 is the spex behind this.
    answer = Slice.next(ctx, %{agent_id: ctx.coding.id})

    refute answer =~ "# Story #{ctx.waiting.number}:",
           "a landed story still moved its team, which is the automatic rebinding " <>
             "retired on 2026-10-07. The move is always an agent's act. Got:\n#{answer}"

    assert held(ctx.coding) == ctx.story.id
    assert held(ctx.qa) == ctx.story.id, "the teammate was pulled with it"
  end
end
