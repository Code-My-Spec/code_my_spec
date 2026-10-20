defmodule CodeMySpec.Agents.StoryAssignmentConsistencyTest do
  use CodeMySpecSpex.Case, async: true

  import CodeMySpec.IssuesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    coding = Fixtures.running_agent(ctx.scope, role: "coding")
    qa = Fixtures.running_agent(ctx.scope, role: "qa")
    ctx = Map.merge(ctx, %{coding: coding, qa: qa}) |> Slice.complete() |> Slice.main_copy()
    ctx
  end

  test "a coder can discover, claim and submit its teammate's assigned story issue", ctx do
    issue = issue_fixture(ctx.scope, %{story_id: ctx.story.id})
    {:ok, issue} = Issues.accept_issue(ctx.scope, issue)

    Repo.get!(Agent, ctx.coding.id)
    |> Ecto.Changeset.change(story_id: nil)
    |> Repo.update!()

    assert Repo.get!(Agent, ctx.qa.id).story_id == ctx.story.id
    discovery = Slice.next(ctx, %{agent_id: ctx.coding.id})
    assert discovery =~ issue.id

    Slice.call(
      ctx,
      "start_task",
      %{
        requirement_name: "submitted",
        entity_type: "issue",
        entity_id: issue.id
      },
      %{agent_id: ctx.coding.id}
    )

    Slice.call(
      ctx,
      "submit_story_issue",
      %{
        issue_id: issue.id,
        revision: "shared-assignment-fix",
        evidence: "Regression verified"
      },
      %{agent_id: ctx.coding.id}
    )

    assert Issues.get_issue(ctx.scope, issue.id).story_submission_revision ==
             "shared-assignment-fix"

    assert Repo.get!(Agent, ctx.qa.id).story_id == ctx.story.id
  end
end
