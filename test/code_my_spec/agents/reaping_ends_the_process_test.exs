defmodule CodeMySpec.Agents.ReapingEndsTheProcessTest do
  @moduledoc """
  A lane going away is not a process exiting.

  `record_reported/2` reconciles what a machine says it is running against what
  the database thinks, and marks anything absent as stopped. That absence is
  real — a lane is joined for exactly as long as its process lives, so a lane
  missing from Presence means the *lane* died.

  It does not mean the OS process died. `reap_if_absent/3` wrote
  `status: :stopped, os_pid: nil` regardless, which is criterion 2828 on the hot
  path: the orphan keeps running, keeps spending, and the group id that could
  have reached it has just been discarded by the reconcile whose job was to
  notice it.

  Three shipped instances of that criterion were found on this project. This is
  the one on the reconcile.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository

  defmodule RefusingTransport do
    @moduledoc "A machine that cannot be reached to end anything."
    @behaviour CodeMySpec.Agents.Transport

    @impl true
    def start_agent(_copy, _agent, _timeout), do: {:error, :harness_not_connected}

    @impl true
    def stop_agent(_copy, _agent, _timeout), do: {:error, :harness_not_connected}
  end

  defmodule EndingTransport do
    @moduledoc "A machine that ends the group and says so."
    @behaviour CodeMySpec.Agents.Transport

    @impl true
    def start_agent(_copy, _agent, _timeout),
      do: {:ok, %{os_pid: 4242, os_boot_id: "boot-abc"}}

    @impl true
    def stop_agent(_copy, agent, _timeout) do
      send(self(), {:asked_to_end, agent.os_pid, agent.os_boot_id})
      :ok
    end
  end

  setup do
    scope = full_scope_fixture()
    previous = Application.get_env(:code_my_spec, :agent_transport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    %{scope: scope}
  end

  defp running_agent(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :pi,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: "coding",
        working_copy_id: scope.active_working_copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :running,
        os_pid: 4242,
        os_boot_id: "boot-abc"
      })

    agent
  end

  test "an absent lane makes the machine end the group before the row says stopped",
       %{scope: scope} do
    Application.put_env(:code_my_spec, :agent_transport, EndingTransport)
    agent = running_agent(scope)

    # The machine reports it is running nothing. Its lane is gone.
    {:ok, _running} = Agents.record_reported(scope, [])

    assert_received {:asked_to_end, 4242, "boot-abc"},
                    "the reconcile marked the agent stopped without asking anybody to " <>
                      "end its process. The lane is gone; the process may not be, and it " <>
                      "is still spending."

    {:ok, reaped} = AgentsRepository.fetch_agent(scope, agent.id)
    assert reaped.status == :stopped
    assert reaped.os_pid == nil
  end

  test "a group that could not be ended keeps its handle and is not called stopped",
       %{scope: scope} do
    Application.put_env(:code_my_spec, :agent_transport, RefusingTransport)
    agent = running_agent(scope)

    {:ok, _running} = Agents.record_reported(scope, [])

    {:ok, after_reap} = AgentsRepository.fetch_agent(scope, agent.id)

    assert after_reap.os_pid == 4242,
           "the group id was discarded while the process may still be running, which " <>
             "is what makes an orphan permanently unreachable — by the reconcile that " <>
             "was supposed to catch it"

    assert after_reap.os_boot_id == "boot-abc",
           "the boot went with it, so even a recovered group id could not be judged"

    refute after_reap.status == :stopped,
           "an agent nothing could end is being reported stopped. An agent that looks " <>
             "running for another cycle is a far better failure than one that looks " <>
             "stopped and is not."
  end

  test "an agent that never came up is reaped without asking anybody", %{scope: scope} do
    Application.put_env(:code_my_spec, :agent_transport, RefusingTransport)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :pi,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: "coding",
        working_copy_id: scope.active_working_copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :starting
      })

    {:ok, _running} = Agents.record_reported(scope, [])

    {:ok, reaped} = AgentsRepository.fetch_agent(scope, agent.id)

    assert reaped.status == :stopped,
           "an agent with no group id has no process to end, so there is nothing to " <>
             "ask and nothing to lose by recording the stop"
  end
end
