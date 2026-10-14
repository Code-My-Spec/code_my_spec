defmodule CodeMySpec.Requirements.IncomingIssuesGateQaTest do
  @moduledoc """
  An issue on a story that nobody has triaged holds that story's QA.

  metric_flow story 47, 2026-09-29: product accepted two highs and skipped the
  low 9e8b52f4, which stayed incoming. `story_issues_resolved` counted only
  accepted issues at the threshold, so QA was re-offered the story, found
  nothing changed that it could see, and tapped out to a human.

  The rules (255f1dcd, 518f2b52):

    * any incoming issue on a story, of any severity, blocks `qa_complete`;
    * triage reaches every severity on a story, so that block can clear;
    * only accepted-open issues at the threshold block QA, so an accepted low
      does not force a fix before re-test;
    * an unlinked incoming medium+ issue is offered for triage whatever its
      scope (129e82f0 was `:qa` and gated nothing).
  """
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.AgentTasks.TriageIssues
  alias CodeMySpec.Issues
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    ctx = FullSatisfactionFixtures.apply_without_qa_story(ctx)
    :ok = Fixtures.settle_graph(ctx.scope)

    assert "qa_complete" in Fixtures.actionable_names(ctx.scope, :qa),
           "premise: QA must be offered the story before any issue is filed"

    ctx
  end

  defp file!(ctx, severity, attrs \\ %{}) do
    {:ok, issue} =
      Issues.create_issue(
        ctx.scope,
        Map.merge(
          %{
            title: "#{severity} finding #{System.unique_integer([:positive])}",
            description: "found in QA",
            severity: severity,
            story_id: ctx.story.id
          },
          attrs
        )
      )

    issue
  end

  defp qa(ctx) do
    :ok = Fixtures.settle_graph(ctx.scope)
    Fixtures.actionable_names(ctx.scope, :qa)
  end

  defp product(ctx) do
    :ok = Fixtures.settle_graph(ctx.scope)
    Fixtures.actionable_names(ctx.scope, :product)
  end

  test "an incoming issue on the story blocks qa_complete, whatever its severity", ctx do
    file!(ctx, :low)

    refute "qa_complete" in qa(ctx),
           "an untriaged low on the story left QA offered the story"
  end

  test "triage-accept then submit and recertify re-offers QA", ctx do
    issue = file!(ctx, :high)
    refute "qa_complete" in qa(ctx)

    {:ok, accepted} = Issues.accept_issue(ctx.scope, issue)
    refute "qa_complete" in qa(ctx), "an accepted high has to be fixed before re-test"

    _coding = Fixtures.running_agent(ctx.scope, role: "coding")

    {:ok, _} =
      CodeMySpec.Agents.assign_team(ctx.scope, ctx.scope.active_working_copy_id, ctx.story.id)

    {:ok, _} =
      Issues.submit_story_issue(ctx.scope, accepted, %{revision: "fix-sha", evidence: "fixed"})

    refute "qa_complete" in qa(ctx), "changed submissions require renewed readiness"
    story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
    {:ok, _} = CodeMySpec.Stories.set_qa_ready(ctx.scope, story, "fix-sha")
    assert "qa_complete" in qa(ctx)
  end

  test "triage-dismiss re-offers QA", ctx do
    issue = file!(ctx, :high)
    refute "qa_complete" in qa(ctx)

    {:ok, _} = Issues.dismiss_issue(ctx.scope, issue, "not a bug")
    assert "qa_complete" in qa(ctx)
  end

  test "a low incoming issue on the story is offered for triage", ctx do
    low = file!(ctx, :low)

    offered = product(ctx)

    # The project node covers story issues at any severity, so it is what
    # product is offered; the story node gates QA behind it.
    assert "issues_triaged" in offered,
           "a low on a story blocks QA, so triage has to reach it: #{inspect(offered)}"

    assert {:ok, :invalid, project} = TriageIssues.evaluate(ctx.scope, %{state: %{}})
    assert project =~ low.title

    assert {:ok, :invalid, story} = TriageIssues.evaluate(ctx.scope, %{story_id: ctx.story.id})
    assert story =~ low.title
  end

  test "an accepted low does not block QA", ctx do
    {:ok, _} = Issues.accept_issue(ctx.scope, file!(ctx, :low))

    assert "qa_complete" in qa(ctx),
           "an accepted low is below the threshold and must not force a fix before re-test"
  end

  test "an unlinked incoming medium+ issue produces a triage offer, whatever its scope", ctx do
    refute "issues_triaged" in product(ctx)

    file!(ctx, :medium, %{story_id: nil, scope: :qa})

    assert "issues_triaged" in product(ctx),
           "129e82f0: a :qa-scoped medium sat incoming and nobody was offered triage"
  end
end
