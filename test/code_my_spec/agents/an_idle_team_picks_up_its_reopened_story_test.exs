defmodule CodeMySpec.Agents.AnIdleTeamPicksUpItsReopenedStoryTest do
  @moduledoc """
  a31f1cd6 / metric_flow: the team's last story was promoted, its agents hold
  no story (the step-3 backfill copied a nil `active_story_id`), and an issue
  accepted on that story reopens it. Nobody selects it; the idle team has to
  find it on its own — reserved to its copy, or released to nobody.
  """

  use CodeMySpecSpex.Case, async: true

  import CodeMySpec.IssuesFixtures
  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    coding = CodeMySpecSpex.Fixtures.running_agent(ctx.scope, role: "coding")
    qa = CodeMySpecSpex.Fixtures.running_agent(ctx.scope, role: "qa")
    ctx = Map.merge(ctx, %{coding: coding, qa: qa}) |> Slice.complete() |> Slice.main_copy()
    story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
    at = DateTime.add(DateTime.utc_now(), -3600)

    {:ok, _} =
      CodeMySpec.Stories.mark_story_promoted(ctx.scope, story, "0.1.15",
        at: at,
        candidate_commit: story.qa_ready_commit,
        commit: story.qa_ready_commit
      )

    Slice.assert_active(Slice.next(ctx, %{agent_id: coding.id}), ctx, "complete")

    # Installed after the fixtures, which swap the transport themselves.
    CodeMySpecTest.RecordingAgentTransport.listen(ctx)

    # The backfill: nobody on the copy holds a story.
    Repo.update_all(
      from(agent in Agent, where: agent.id in ^[coding.id, qa.id]),
      set: [story_id: nil, continuous: true]
    )
    %{ctx | coding: reload(coding), qa: reload(qa)}
  end

  defp reload(agent), do: Repo.get!(Agent, agent.id)

  defp reopen(ctx) do
    issue = issue_fixture(ctx.scope, %{story_id: ctx.story.id})
    {:ok, issue} = Issues.accept_issue(ctx.scope, issue)
    issue
  end

  defp release(ctx, false), do: ctx

  defp release(ctx, true) do
    Repo.update_all(
      from(story in Story, where: story.id == ^ctx.story.id),
      set: [working_copy_id: nil]
    )
    ctx
  end

  defp offered(ctx, agent) do
    ctx.scope
    |> Work.claimable_work(reload(agent))
    |> Enum.map(&{&1.name, to_string(&1.entity_id)})
  end

  defp start(ctx, agent, issue) do
    Slice.call(
      ctx,
      "start_task",
      %{requirement_name: "submitted", entity_type: "issue", entity_id: issue.id},
      %{agent_id: agent.id}
    )
  end

  for {label, released?} <- [{"reserved to this copy", false}, {"unassigned", true}] do
    @released released?

    test "a reopened story #{label} is picked up and seen through", ctx do
      ctx = release(ctx, @released)
      issue = reopen(ctx)
      story_id = to_string(ctx.story.id)

      assert {"submitted", issue.id} in offered(ctx, ctx.coding),
             "the idle coder is offered the reopened story's issue work"

      coding_id = ctx.coding.id

      # The graph's own wake runs off-process; asking here as it does makes the
      # offer deterministic, and whichever of the two lands first is the turn.
      Work.consider_project(ctx.scope, :graph_changed)

      assert_receive {:work_turn_requested, ^coding_id, ref, _prompt},
                     500,
                     "the idle continuous coder is offered the reopened story"

      # The test takes the task itself, so the turn it was handed is withdrawn.
      :ok = Offers.withdraw(%Offer{id: ref})

      start(ctx, ctx.coding, issue)

      assert reload(ctx.coding).story_id == ctx.story.id
      assert reload(ctx.qa).story_id == ctx.story.id, "the whole team takes the story"

      coding = reload(ctx.coding)
      [task] = Enum.filter(coding.tasks || [], &(&1.status == :active))

      {:ok, _} =
        Issues.submit_story_issue(ctx.scope, issue, %{revision: "fix-sha", evidence: "fixed"})

      {:ok, _} = CodeMySpec.TaskOwner.complete_task(ctx.scope, coding, task.id)

      refute {"story_promoted", story_id} in offered(ctx, ctx.coding),
             "a changed fix must be reviewed before another promotion"

      story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
      {:ok, _} = CodeMySpec.Stories.set_qa_ready(ctx.scope, story, "fix-sha")
      {_, qa_task_id, _} = CodeMySpecSpex.Fixtures.qa_story_task_fixture(ctx.scope, story: story)

      {:ok, _} =
        CodeMySpec.Qa.submit_qa_result(ctx.scope, %{
          task_id: qa_task_id,
          status: :pass,
          issue_ids: [],
          scenarios: [%{name: "Fix reviewed", status: :pass, observation: "fixed"}]
        })

      assert {"story_promoted", story_id} in offered(ctx, ctx.coding),
             "after the fix, the story goes back to promote"

      assert reload(ctx.coding).story_id == ctx.story.id
      assert reload(ctx.qa).story_id == ctx.story.id

      story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
      at = DateTime.add(DateTime.utc_now(), 1)

      {:ok, _} =
        CodeMySpec.Qa.complete_reviewed_story_issues(ctx.scope, story, "landed-sha", "fix-sha")

      {:ok, _} = CodeMySpec.Stories.mark_story_promoted(ctx.scope, story, "0.1.16", at: at)
      :ok = CodeMySpec.Requirements.GraphWatcher.settle(ctx.scope)

      Slice.assert_active(Slice.next(ctx, %{agent_id: ctx.coding.id}), ctx, "complete")
      assert reload(ctx.qa).story_id == ctx.story.id
    end
  end
end
