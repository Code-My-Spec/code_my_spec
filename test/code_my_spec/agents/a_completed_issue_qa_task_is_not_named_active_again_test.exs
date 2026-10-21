defmodule CodeMySpec.Agents.ACompletedIssueQaTaskIsNotNamedActiveAgainTest do
  @moduledoc """
  28690eba: a QA agent submitted a failing issue QA attempt (completing the
  task), called `evaluate_task` on that same task id and correctly got
  "already completed", then -- after ending the turn -- the next wake named
  the same, already-completed task as still active, asking the agent to
  disposition it again.

  Reproduces the reported sequence literally: `submit_issue_qa_result` (the
  completion), `evaluate_task` on the same task id (the "already completed"
  reply), then the Stop hook decision a real Claude Code session's next turn
  would receive. Not reproducible on current code: `Qa.IssueQaAttempts.submit/4`
  completes the task inside the same transaction as the attempt write, so by
  the time any later read happens -- a fresh `fetch_agent`, or the hook's own
  decision -- the task is already gone from `active_task/1`, and the hook
  correctly has nothing to say.

  The sibling issue 4100468a (same incident, same underlying issue 5914090f)
  already traced this exact completion path and found no `:tasks, :completed`
  telemetry fires from it at all -- `Qa.IssueQaAttempts` calls
  `TaskOwner.complete_task/4` directly, never through `AgentTasks.TaskEvaluator`,
  the only emitter of that event. With no async wake firing from this path,
  there is no mechanism left that could deliver a directive computed from a
  stale, pre-completion snapshot: every read of this agent's state after this
  point goes straight to the row this transaction wrote.
  """
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Tools.EvaluateTask
  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.Qa

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.TerminalAgentFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "a failed issue QA's task stays cleared through evaluate_task and the next stop", ctx do
    issue = issue_fixture(ctx.scope, %{title: "t", description: "d"})
    other_issue = issue_fixture(ctx.scope, %{title: "t2", description: "d2"})

    session_id = "cc-#{System.unique_integer([:positive])}"
    task_id = Ecto.UUID.generate()

    agent =
      terminal_agent_fixture(ctx.scope, %{
        role: :qa,
        engine_session_id: session_id,
        tasks: [
          %{
            id: task_id,
            status: :active,
            session_type: CodeMySpec.AgentTasks.IssueQa,
            requirement_name: "qa_complete",
            issue_id: issue.id,
            started_at: DateTime.utc_now()
          }
        ]
      })

    assert %{id: ^task_id} = Agent.active_task(agent)

    assert {:ok, _attempt} =
             Qa.submit_issue_qa_result(ctx.scope, agent, %{
               status: "fail",
               task_id: task_id,
               issue_id: issue.id,
               scenarios: [%{name: "s", status: "fail", observation: "broke"}],
               issue_ids: [other_issue.id]
             })

    assert {:ok, body} =
             EvaluateTask.call(
               %{task_id: task_id, session_id: session_id},
               %{scope: ctx.scope, agent_id: agent.id}
             )

    assert body =~ "already completed"

    {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, agent.id)

    refute Agent.active_task(fresh),
           "the task read back from a fresh fetch still shows active after its own completion"

    assert Stop.decide(ctx.scope, %{"session_id" => session_id}) == %{},
           "the next stop decision named something to say about a task that is already done"
  end
end
