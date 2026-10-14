defmodule CodeMySpec.McpServers.Tasks.AStoryTaskResumesDespiteAnUnrelatedIssueBindingTest do
  @moduledoc """
  Issue ae97b26c: an agent holding a blocked story-type task, whose blocker
  was released, could not resume it via `start_task` once the SAME working
  copy also held an accepted issue in its bag -- refused with
  "Cannot resume task ...: :requirement_not_eligible", as if the story task
  itself had gone ineligible.

  Traced: `eligible_to_resume/3` checked `Work.actionable/3`, which answers
  "what should this agent do next" and deliberately bypasses the whole
  requirement graph -- answering only issue work -- the moment the working
  copy's issue bag is non-empty (`Work.work_for/4`'s own moduledoc: "an
  agent bound to an issue... bypasses the graph entirely"). That rule is
  right for dispatch, but wrong for asking whether an EXISTING story task is
  still eligible to resume: the story task was never actually ineligible,
  it was just hidden by an unrelated issue sitting in the copy's bag.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpec.IssuesFixtures
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.WithdrawQuestion
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  setup :synced_context_component

  defp reload(agent), do: CodeMySpec.Repo.get!(Agents.Agent, agent.id)

  test "start_task resumes the story task once its blocker is withdrawn, even with an issue in the copy's bag",
       context do
    context = ProjectStateFixtures.apply_project_kickoff(context)

    story =
      StoryHelpers.create_and_link(context.scope, context.component.module_name,
        title: "A story whose task must survive an unrelated issue binding",
        description: "Blocked, released, and resumed while the copy also holds an issue.",
        acceptance_criteria: ["The stated behavior is implemented"]
      )

    :ok =
      ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
        persona_id: context.persona_id
      )

    coding = Fixtures.running_agent(context.scope, role: "coding")
    :ok = Agents.claim_story(context.scope, coding, story.id)

    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}

    params = %{
      requirement_name: "bdd_specs_exist",
      entity_type: "story",
      entity_id: to_string(story.number)
    }

    {:reply, started, _} = StartTask.execute(params, frame)
    refute started.isError, inspect(started)
    [task] = reload(coding).tasks

    {:reply, asked, _} =
      AskUserQuestion.execute(
        %{
          task_id: task.id,
          questions: [%{question: "Which criteria first?", options: []}]
        },
        frame
      )

    refute asked.isError, inspect(asked)

    [%{status: :blocked, blocker_resolved_at: nil, blocker_id: question_id}] =
      reload(coding).tasks

    {:reply, withdrawn, _} =
      WithdrawQuestion.execute(%{question_id: question_id, reason: "moot"}, frame)

    refute withdrawn.isError, inspect(withdrawn)
    assert [%{status: :blocked, blocker_resolved_at: %DateTime{}}] = reload(coding).tasks

    # The premise: an accepted issue sits in this SAME working copy's bag --
    # written directly via `Issues.set_assigned_working_copy/3`, the same
    # field `IssueAssignment.bag/2` (and so `Work.actionable/3`'s
    # issue-binding check) reads, rather than through
    # `Agents.assign_issue_to_working_copy/4`: that tool also runs
    # `Assignment.clear_for_issues/2`, which deliberately cancels a copy's
    # story work the moment an issue lands on it -- a separate, correct
    # behavior that would make this test's own premise (a resumable story
    # task coexisting with an issue in the bag) impossible to set up.
    issue = issue_fixture(context.scope, %{status: :accepted})
    {:ok, _issue} = Issues.set_assigned_working_copy(context.scope, issue, coding.working_copy_id)

    {:reply, resumed, _} = StartTask.execute(params, frame)

    refute resumed.isError,
           "start_task refused to resume the story task because the copy also holds an " <>
             "unrelated issue in its bag: #{inspect(resumed)}"

    assert [%{id: task_id, status: :active, blocker_id: nil}] = reload(coding).tasks
    assert task_id == task.id
  end
end
