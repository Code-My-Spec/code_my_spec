defmodule CodeMySpec.Agents.ARestartStopsTheProcessFirstTest do
  @moduledoc """
  A restart replaces the process, rather than being handed the live one back.

  Issue `e9f9a5ab`. `restart_agent/2` never stopped anything — it set the row to
  `:starting`, nilled the pid and called `launch/2`, which reaches the harness's
  `Engine.start/1`. That answers `{:error, {:already_started, pid}}` with `{:ok,
  %{pid: pid}}`: correct idempotence for a re-delivered *start*, and wrong for a
  restart. The live process came straight back, its turn carried on, and the
  only thing that reached it was the `Restarted: <reason>` message sent
  afterwards.

  So the remedy was a no-op against the one agent worth applying it to. An agent
  hung mid-turn has a live process, and that is the case story 1059 exists for.
  Every restart reported success while changing nothing.

  Nothing caught it because nothing watched the machine. The existing fake
  answers a stop with a bare `:ok` and tells no one, so "stopped then started"
  and "started only" produce identical observable behaviour — which is why the
  assertion here is on the *order of what the machine was asked*, not on the
  row, and not on the return value. Both of those were fine throughout.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpecTest.RestartWatchingTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RestartWatchingTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RestartWatchingTransport.listen()

    # A restart fetches a credential before it does anything else, and this
    # project has no connected integration — so without a platform key the call
    # fails at that step and never reaches the part under test.
    previous_credential = Application.get_env(:code_my_spec, CodeMySpec.Agents.Credential, [])

    Application.put_env(
      :code_my_spec,
      CodeMySpec.Agents.Credential,
      Keyword.put(previous_credential, :platform_api_key, "sk-platform-for-this-test")
    )

    on_exit(fn ->
      Application.put_env(:code_my_spec, CodeMySpec.Agents.Credential, previous_credential)
    end)

    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        working_copy: "/tmp/restart-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    %{scope: scope, agent: agent}
  end

  test "the machine is asked to stop it before it is asked to start it", %{
    scope: scope,
    agent: agent
  } do
    {:ok, _restarted} = Agents.restart_agent(scope, agent.id)

    agent_id = agent.id

    assert_received {:machine, :stop, ^agent_id}, """
    The machine was never asked to stop this agent, so a live process is handed
    straight back by Engine.start/1 and carries on with the turn it was in. The
    restart reports success and changes nothing — which is the whole of
    e9f9a5ab, and is invisible from the row, the return value and every other
    assertion in this suite.
    """

    assert_received {:machine, :start, ^agent_id},
                    "stopping is not restarting — it has to come back up"
  end

  test "and in that order", %{scope: scope, agent: agent} do
    {:ok, _restarted} = Agents.restart_agent(scope, agent.id)

    assert [{:machine, :stop, _}, {:machine, :start, _}] = drain(), """
    The machine was asked to start before it was asked to stop, so the start
    found the old process still there and was given it back — the exact
    behaviour the stop exists to prevent.
    """
  end

  defp drain(collected \\ []) do
    receive do
      {:machine, _what, _id} = call -> drain([call | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end
end
