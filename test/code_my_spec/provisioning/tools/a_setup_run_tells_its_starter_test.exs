defmodule CodeMySpec.Provisioning.Tools.ASetupRunTellsItsStarterTest do
  @moduledoc """
  The 1599c109 gap, for `run_devops_setup`: the agent that started a setup run
  is held while it runs and messaged how it ended.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.Provisioning.Tools.RunDevopsSetup

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Waiting
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    previous_async = Application.get_env(:code_my_spec, :provisioning_async)
    previous_opts = Application.get_env(:code_my_spec, :provisioning_step_opts, [])
    Application.put_env(:code_my_spec, :provisioning_async, true)

    test = self()

    # The first step waits for the test, so the run is observably in flight.
    Application.put_env(:code_my_spec, :provisioning_step_opts,
      verify: fn _scope, _key -> {:ok, :absent} end,
      execute: fn _scope, _key, _opts -> step(test, Process.get(:released)) end
    )

    on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_async, previous_async)
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous_opts)
    end)

    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        status: :running,
        working_copy: "/tmp/setup-starter-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    %{scope: scope, agent: agent}
  end

  test "the starter waits on the run, then is told how it ended", %{scope: scope, agent: agent} do
    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    {response, run_tasks} = run_setup(frame)
    assert response_text(response) =~ "you'll be messaged how it ends"

    assert_receive {:step_running, step}, 5_000
    assert %{label: "devops setup"} = RunLock.held_by(agent.id)
    assert Waiting.reason(scope, agent, :wake) == {:provisioning, "devops setup"}

    send(step, :go)

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
    assert message =~ "devops setup"
    assert message =~ "finished"

    await(run_tasks)
    assert RunLock.held_by(agent.id) == nil
  end

  test "a caller with no agent is told to watch devops_status", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    {response, run_tasks} = run_setup(frame)
    assert response_text(response) =~ "devops_status"

    assert_receive {:step_running, step}, 5_000
    send(step, :go)
    await(run_tasks)

    refute_received {:agent_dispatch, _, _, _}
  end

  describe "outcome_message/2" do
    test "paused carries the reason" do
      run = %{steps: [%{state: :paused}], halted_at: :inbound, reason: "needs an address"}

      assert RunDevopsSetup.outcome_message(run, "MF") =~
               "Your devops setup for MF paused at inbound: needs an address"
    end

    test "errored carries the error" do
      run = %{steps: [%{state: :errored}], halted_at: :deploy, reason: "docker build failed"}

      assert RunDevopsSetup.outcome_message(run, "MF") =~
               "Your devops setup for MF errored at deploy: docker build failed"
    end
  end

  defp step(_test, true), do: {:ok, []}

  defp step(test, _released) do
    send(test, {:step_running, self()})
    receive do: (:go -> Process.put(:released, true))
    {:ok, []}
  end

  defp run_setup(frame) do
    before = Task.Supervisor.children(CodeMySpec.TaskSupervisor)

    response =
      ToolLibrary.run(
        "run_devops_setup",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    {response, Task.Supervisor.children(CodeMySpec.TaskSupervisor) -- before}
  end

  defp await(pids) do
    for pid <- pids do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp response_text({_status, text}), do: text
end
