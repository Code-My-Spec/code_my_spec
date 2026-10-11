defmodule CodeMySpec.Requirements.HandlersTest do
  @moduledoc """
  A handler has to agree with the checker it replaces — in both directions, and
  in what it says, not only in what it decides.

  The verdict is what the shadow diff compares, so a wrong one is caught
  eventually. The *details* are not compared, which is exactly why they need
  pinning here: a handler that reads `false` correctly while explaining itself
  differently produces rows that look wrong to whoever reads them next, and
  nothing fails. One had already drifted when this was written —
  `issues_resolved` said "No unresolved issues at medium+ severity" where the
  checker says "No unresolved medium+ issues" — and it was invisible because
  that requirement happened to be unsatisfied on the project it was checked
  against.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.IssuesChecker
  alias CodeMySpec.Requirements.Requirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp sweep(scope, name) do
    {:ok, _changes, sweeps} = Handlers.apply_event(scope, "issue_created", %{})
    Enum.find(sweeps, &(&1.name == name))
  end

  defp normalized({satisfied, details}), do: {satisfied, Requirement.normalize_details(details)}

  describe "issues" do
    test "agrees with the checkers when there are no issues", ctx do
      create_story(ctx.scope, title: "Clean", description: "no issues")

      for {name, checked} <- [
            {"issues_triaged", IssuesChecker.triaged?(ctx.scope, ctx.scope.active_project)},
            {"issues_resolved", IssuesChecker.resolved?(ctx.scope, ctx.scope.active_project)}
          ] do
        sw = sweep(ctx.scope, name)
        {satisfied, details} = normalized(checked)

        assert sw.default == satisfied, "#{name}: handler and checker disagree"

        assert sw.default_details == details,
               "#{name}: handler and checker explain it differently"
      end
    end

    test "agrees with the checkers on an accepted issue, verdict and wording", ctx do
      story = create_story(ctx.scope, title: "Blamed", description: "carries an issue")

      {:ok, issue} =
        CodeMySpec.Issues.create_issue(ctx.scope, %{
          title: "something broke",
          description: "and it is accepted",
          severity: :high,
          story_id: story.id
        })

      {:ok, _} = CodeMySpec.Issues.accept_issue(ctx.scope, issue)

      sw = sweep(ctx.scope, "issues_resolved")

      {satisfied, details} =
        normalized(IssuesChecker.resolved?(ctx.scope, ctx.scope.active_project))

      assert sw.default == satisfied
      assert sw.default_details == details

      # And the story, through the grouped read rather than a per-story query.
      story_sweep = sweep(ctx.scope, "story_issues_resolved")
      named = Enum.find(story_sweep.except, &(&1.entity_id == story.id))

      {story_satisfied, story_details} =
        normalized(IssuesChecker.story_resolved?(ctx.scope, %{id: story.id}))

      refute story_satisfied, "the fixture did not produce an unresolved story"
      assert named, "the grouped read did not name the story carrying the issue"
      assert named.satisfied == story_satisfied
      assert named.details == story_details
    end

    test "a story with no issues is satisfied by absence, not by a query", ctx do
      clean = create_story(ctx.scope, title: "Clean", description: "no issues")

      story_sweep = sweep(ctx.scope, "story_issues_resolved")

      # The whole point of the sweep: a story the profile did not name takes the
      # default, so one grouped query settles every story rather than one query
      # per story.
      assert story_sweep.default == true
      refute Enum.any?(story_sweep.except, &(&1.entity_id == clean.id))

      {satisfied, details} = normalized(IssuesChecker.story_resolved?(ctx.scope, %{id: clean.id}))
      assert satisfied
      assert story_sweep.default_details == details
    end
  end

  describe "an unknown event" do
    test "answers :no_handler so the caller re-derives", ctx do
      assert Handlers.apply_event(ctx.scope, "something_nobody_handles", %{}) == :no_handler
    end
  end
end
