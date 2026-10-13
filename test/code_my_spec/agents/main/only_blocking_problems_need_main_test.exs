defmodule CodeMySpec.Agents.Main.OnlyBlockingProblemsNeedMainTest do
  @moduledoc """
  The problems main is shown for an agent's checkout are the ones that can
  block, by the same predicate the gate uses.

  Advisory findings were counted, so every check-in put team 2 under "Needs
  you: 45 checkout problems" for credo :info findings the gate passed on every
  batch (2026-10-13).
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main.WorkRepository
  alias CodeMySpec.Configurations
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :coding,
        status: :running,
        working_copy: "/tmp/only-blocking",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    problem_fixture(scope, %{severity: :info, message: "No more than 1 consecutive blank line"})
    problem_fixture(scope, %{severity: :error, message: "undefined function frob/0"})
    %{scope: scope}
  end

  defp messages(scope) do
    [%{problems: problems}] = WorkRepository.list_agent_work(scope)
    Enum.map(problems, & &1.message)
  end

  test "an advisory finding is not a problem main is shown", %{scope: scope} do
    assert messages(scope) == ["undefined function frob/0"]
  end

  test "it is when the project says advisory findings block", %{scope: scope} do
    {:ok, _} = Configurations.update(scope, %{advisory_findings: :block})

    assert Enum.sort(messages(scope)) ==
             ["No more than 1 consecutive blank line", "undefined function frob/0"]
  end
end
