defmodule CodeMySpec.Promotion.AFixResolvedAfterPromotionIsPromotedAgainTest do
  @moduledoc """
  1f8028a1: issue b4e19491 on metric_flow's story 8 (stamped 0.1.15) was fixed
  on a feature copy and resolved. The stamp said the story was promoted, every
  requirement read satisfied, and nothing offered the promote that would carry
  the fix to main.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Issues
  alias CodeMySpec.Promotion.RunningCopy
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Staffing
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, main} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, _} = Staffing.designate_main(scope, main.id)
    %{scope: scope, story: story_fixture(scope)}
  end

  defp promote(scope, story, at) do
    {:ok, story} = Stories.mark_story_promoted(scope, story, "0.1.15", at: at, commit: "abc")
    story
  end

  defp resolve(scope, story) do
    issue = issue_fixture(scope, %{story_id: story.id})
    {:ok, issue} = Issues.accept_issue(scope, issue)
    {:ok, issue} = Issues.resolve_issue(scope, issue, "fixed")
    issue
  end

  # Both paths go through the same verdict; asked both ways so they can't drift.
  defp verdicts(scope, story) do
    {_unpromoted, promoted} = RunningCopy.running_copy_verdicts(scope, [story])
    {RunningCopy.running_copy_check(scope, story), promoted[story.id]}
  end

  test "a fix resolved after the last promotion needs promoting again", ctx do
    story = promote(ctx.scope, ctx.story, DateTime.add(DateTime.utc_now(), -3600))
    issue = resolve(ctx.scope, story)

    {check, swept} = verdicts(ctx.scope, story)
    assert check == swept
    assert {false, %{reason: reason}} = check
    assert reason =~ issue.id
    assert reason =~ "Promote this story again"
  end

  test "promoting again carries it", ctx do
    story = promote(ctx.scope, ctx.story, DateTime.add(DateTime.utc_now(), -3600))
    resolve(ctx.scope, story)

    story = promote(ctx.scope, story, DateTime.add(DateTime.utc_now(), 1))

    assert {{true, _}, {true, _}} = verdicts(ctx.scope, story)
  end

  test "a fix resolved before the promotion is already on main", ctx do
    resolve(ctx.scope, ctx.story)
    story = promote(ctx.scope, ctx.story, DateTime.add(DateTime.utc_now(), 1))

    assert {{true, _}, {true, _}} = verdicts(ctx.scope, story)
  end

  # The verdict above is the mechanism; this is the issue's own claim, that
  # nobody is offered the promote. It asks the graph, which is what an offer
  # reads, rather than `RunningCopy` directly.
  test "the graph reads story_promoted unsatisfied once the fix is resolved", ctx do
    story = promote(ctx.scope, ctx.story, DateTime.add(DateTime.utc_now(), -3600))
    assert [{true, _}] = story_promoted(ctx.scope, story), "a stamped story with no fix is satisfied"

    issue = resolve(ctx.scope, story)

    assert [{false, details}] = story_promoted(ctx.scope, story)
    assert details["reason"] =~ issue.id
  end

  defp story_promoted(scope, story) do
    {nodes, _edges} = RequirementGraph.compute_graph(scope)

    found = Enum.filter(nodes, &(&1.name == "story_promoted" and &1.entity_id == story.id))
    Enum.map(found, &{&1.satisfied, &1.details})
  end
end
