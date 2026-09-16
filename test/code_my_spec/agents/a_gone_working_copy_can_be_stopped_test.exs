defmodule CodeMySpec.Agents.AGoneWorkingCopyCanBeStoppedTest do
  @moduledoc """
  `stop_agent` refuses an unreachable harness, and that refusal has to know
  the difference between "down for now" and "never coming back".

  Issue `8b591eba`: four agents on a working copy that no longer existed sat
  `running` forever, each refusing `stop_agent` with `:harness_not_connected`
  — the same refusal a merely-disconnected machine gets, even though nothing
  is left anywhere to hold the process the refusal is protecting.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpecTest.UnreachableMachine

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, UnreachableMachine)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    %{scope: full_scope_fixture()}
  end

  test "an agent on a working copy that no longer exists is stopped, not refused", %{
    scope: scope
  } do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        status: :running,
        working_copy: "/tmp/cms-qa-agents/agent-1",
        working_copy_id: scope.active_working_copy_id
      })

    # What the working copy's own deletion leaves behind: `on_delete:
    # :nilify_all` on `agents_working_copy_id_fkey` sets this column directly
    # at the database level. Not reachable through `AgentsRepository` at all
    # — `validate_required` guards `working_copy_id` on every changeset path
    # — which is exactly why the row exists in this shape without anything
    # here having chosen it.
    Repo.update_all(from(a in Agent, where: a.id == ^agent.id), set: [working_copy_id: nil])

    assert {:ok, stopped} = Agents.stop_agent(scope, agent.id), """
    stop_agent refused an agent whose working copy resolves to nothing. That
    refusal is protecting a process on a machine we cannot reach — and a
    working copy that does not exist has no machine to protect one on, so the
    row is stuck `running` forever with no way to retire it.
    """

    assert stopped.status == :stopped
  end

  test "an agent on a working copy that still exists is still refused, unreachable or not", %{
    scope: scope
  } do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        working_copy: "/tmp/still-a-real-copy",
        working_copy_id: scope.active_working_copy_id
      })

    assert {:error, :harness_not_connected} = Agents.stop_agent(scope, agent.id), """
    A working copy that still exists may still be running the process this
    stop was for — the machine is merely unreachable from here, not gone.
    Reporting this as stopped would be exactly the regression criterion 2828
    exists to prevent: a row saying stopped over something still running.
    """
  end
end
