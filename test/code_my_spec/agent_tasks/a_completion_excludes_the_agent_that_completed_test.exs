defmodule CodeMySpec.AgentTasks.ACompletionExcludesTheAgentThatCompletedTest do
  @moduledoc """
  4427e406. Finishing a task wakes the other agents on its copy; the one that
  finished is told directly and must be left out. The wake passed the task's
  `agent_id` (the sub-agent label of an old session-owned task, never an
  `Agents.Agent` id) as the agent to exclude, so it never matched anyone and the
  finishing agent was reconsidered like a bystander.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.TerminalAgentFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.TaskEvaluator

  setup do
    scope = full_scope_fixture()
    agent = terminal_agent_fixture(scope)
    test = self()

    handler = "completion-wake-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:code_my_spec, :tasks, :completed],
      fn _event, _measurements, meta, _config -> send(test, {:completed, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{scope: scope, agent: agent}
  end

  test "the wake excludes the agent whose task completed", %{scope: scope, agent: agent} do
    scope = %{scope | active_working_copy_id: Ecto.UUID.generate()}

    :ok = TaskEvaluator.reconsider_other_agents(scope, agent)

    assert_receive {:completed, meta}
    assert meta.except_agent_id == agent.id
    assert meta.working_copy_id == scope.active_working_copy_id
  end

  test "with no working copy there is nobody to wake", %{scope: scope, agent: agent} do
    scope = %{scope | active_working_copy_id: nil}

    assert :ok = TaskEvaluator.reconsider_other_agents(scope, agent)
    refute_receive {:completed, _meta}, 50
  end
end
