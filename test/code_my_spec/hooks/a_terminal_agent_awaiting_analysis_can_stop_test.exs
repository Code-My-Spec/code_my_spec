defmodule CodeMySpec.Hooks.ATerminalAgentAwaitingAnalysisCanStopTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.TerminalAgentFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.Repo

  defp prepare_run(_run, :queued), do: :ok

  defp prepare_run(run, :executing) do
    RunsRepository.record_tree(run, %{
      began_at: DateTime.utc_now(),
      start_commit: String.duplicate("a", 40),
      start_tree_dirty: false
    })
  end

  defp task_attributes(scope, :issue_qa) do
    issue = issue_fixture(scope)

    {:qa,
     %{
       session_type: CodeMySpec.AgentTasks.IssueQa,
       requirement_name: "qa_complete",
       issue_id: issue.id
     }}
  end

  defp task_attributes(scope, :ready_for_qa) do
    story = CodeMySpec.StoriesFixtures.story_fixture(scope)

    {:coding,
     %{
       session_type: CodeMySpec.AgentTasks.ReadyForQa,
       requirement_name: "ready_for_qa",
       story_id: story.id
     }}
  end

  for state <- [:queued, :executing], kind <- [:issue_qa, :ready_for_qa] do
    @state state
    @kind kind
    test "#{kind} may stop while its analysis is #{state}" do
      scope = full_scope_fixture()

      {:ok, copy} =
        CodeMySpec.WorkingCopies.issue(scope, nil,
          label: "analysis wait",
          device: device_fixture(scope)
        )

      scope = %{scope | active_working_copy_id: copy.id, cwd: nil}

      {role, task_attrs} = task_attributes(scope, @kind)

      agent =
        terminal_agent_fixture(scope, %{
          role: role,
          continuous: true,
          tasks: [
            Map.merge(task_attrs, %{
              status: :active,
              project_id: scope.active_project_id,
              started_at: DateTime.utc_now()
            })
          ]
        })

      task = Agent.active_task(agent)

      {:ok, run} =
        RunsRepository.start_run(scope, %{
          source: "exunit",
          kind: :full,
          requested_by: %{kind: "mcp_tool", tool: "start_analysis", agent_id: agent.id}
        })

      prepare_run(run, @state)

      assert Analysis.awaiting_runs?(scope, copy.id, agent.id)

      response = Stop.decide(scope, %{"session_id" => agent.engine_session_id})

      refute response["decision"] == "block", inspect(response)
      assert String.downcase(Jason.encode!(response)) =~ "waiting"
      persisted = Agent.active_task(Repo.get!(Agent, agent.id))
      assert persisted.id == task.id
      assert persisted.evaluation_feedback_count == task.evaluation_feedback_count

      {:ok, _} = RunsRepository.finish_run(run, :completed)
      refute Analysis.awaiting_runs?(scope, copy.id, agent.id)

      {:ok, _other_run} =
        RunsRepository.start_run(scope, %{
          source: "credo",
          kind: :full,
          requested_by: %{
            kind: "mcp_tool",
            tool: "start_analysis",
            agent_id: Ecto.UUID.generate()
          }
        })

      settled_response = Stop.decide(scope, %{"session_id" => agent.engine_session_id})
      assert settled_response["decision"] == "block", inspect(settled_response)
      assert Agent.active_task(Repo.get!(Agent, agent.id)).id == task.id
    end
  end
end
