defmodule CodeMySpec.Agents.AnOfferRespectsTheTeamsIssueAssignmentTest do
  @moduledoc """
  2c435ea1. A QA agent on a team assigned an issue still being fixed was woken
  with `requirement:story:603:qa_complete`; its own `get_next_requirement` said
  blocked and `start_task` refused story 603. An agent is never offered work its
  discovery and claim refuse, whether the offer is made after the assignment or
  was already standing when it came.
  """

  # Not async: a recorded transport and the shared sandbox.
  use CodeMySpecSpex.Case, async: false

  import CodeMySpec.IssuesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  # QA's story is waiting for it; the team is free, so QA is offered it.
  setup ctx do
    RecordingAgentTransport.listen(ctx)

    coding = continuous_agent(ctx, "coding")
    qa = continuous_agent(ctx, "qa")

    ctx =
      ctx
      |> Map.merge(%{coding: coding, qa: qa})
      |> CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story()
      |> Slice.activate()
      |> Slice.waiting()

    issue = issue_fixture(ctx.scope, %{story_id: nil})
    {:ok, issue} = Issues.accept_issue(ctx.scope, issue)
    Map.merge(ctx, %{issue: issue, qa: Repo.get!(Agent, qa.id)})
  end

  defp continuous_agent(ctx, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: true,
        status: :running,
        working_copy: "/tmp/team-#{role}-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    agent
  end

  defp assign_issue(ctx),
    do: {:ok, _} = IssueAssignment.assign(ctx.scope, ctx.issue.id, ctx.qa.working_copy_id)

  defp qa(ctx), do: Repo.get!(Agent, ctx.qa.id)

  test "the premise: before the assignment QA has story work to take", ctx do
    assert [%{name: "qa_complete"}] = Work.claimable_work(ctx.scope, qa(ctx))
  end

  test "assigned an issue still being fixed, QA has nothing claimable or offered", ctx do
    assign_issue(ctx)

    assert Work.claimable_work(ctx.scope, qa(ctx)) == []
    refute Slice.next(ctx, %{agent_id: ctx.qa.id}) =~ "qa_complete"
    assert {:ok, :not_runnable} = Work.request_turn_if_runnable(ctx.scope, qa(ctx), :test)
  end

  test "an offer already standing when the assignment came is withdrawn", ctx do
    {:ok, _} = Work.request_turn_if_runnable(ctx.scope, qa(ctx), :test)
    standing = Offers.current_work_offer(ctx.qa.id)
    assert standing, "the premise: QA was offered its story's qa_complete"

    assign_issue(ctx)

    # A wake already computing under the old assignment withdraws what it made
    # once it sees the new one, a moment later.
    eventually(fn ->
      assert Offers.current_work_offer(ctx.qa.id) == nil,
             "the standing offer for #{standing.subject_key} outlived the assignment that " <>
               "made it unclaimable, so QA is still shown it as backed by an offer"
    end)
  end
end
