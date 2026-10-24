defmodule CodeMySpec.AppInstances.Tools.StopAppReturnsAtOnceAndIsMessagedLaterTest do
  @moduledoc """
  Issue f2977826, batch 2 of 4f7929e4: `stop_app` declared the full 30s of
  the code-mode sandbox's wall clock with no margin at all to even return an
  answer afterward. Same lock-then-ack handshake `run_provisioning_step`
  already uses (see `a_finished_step_wakes_its_starter_test.exs`): a spawned
  task claims `AppRunLock` first and only then acks, so the caller learns
  "started" in milliseconds and is messaged the outcome once the real stop
  lands.

  A fake harness process stands in for the working copy's own machine, the
  same way `EnsureAppRunningRevisionTest` already does.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures

  setup do
    previous_async = Application.get_env(:code_my_spec, :working_copies_app_run_async)
    Application.put_env(:code_my_spec, :working_copies_app_run_async, true)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :working_copies_app_run_async, previous_async)
    end)

    # The run spawns a detached task, which checks out its own connection.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = working_copy_scope_fixture()
    RecordingAgentTransport.listen(scope)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        status: :running,
        working_copy: scope.cwd,
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    %{scope: scope, agent: agent}
  end

  test "returns at once, and the agent is told it stopped", %{scope: scope, agent: agent} do
    start_fake_harness(scope, fn
      :stop_app, from -> GenServer.reply(from, :ok)
    end)

    {response, task_pids} = call("stop_app", %{}, %{scope: scope, agent_id: agent.id})

    assert response_text(response) =~ "Stopping"
    assert response_text(response) =~ "you'll be messaged how it ends"

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
    assert message == "Stopped."

    await(task_pids)
  end

  test "a caller with no agent is told to call this tool again", %{scope: scope} do
    start_fake_harness(scope, fn
      :stop_app, from -> GenServer.reply(from, :ok)
    end)

    {response, task_pids} = call("stop_app", %{}, %{scope: scope})

    assert response_text(response) =~ "call this tool again"

    await(task_pids)
    refute_received {:agent_dispatch, _, _, _}
  end

  defp start_fake_harness(scope, reply_fn) do
    caller = self()

    pid =
      spawn_link(fn ->
        :ok =
          HarnessRegistry.register_executor(
            scope.active_working_copy_id,
            "stop-app-test",
            "/tmp/stop-app-test"
          )

        send(caller, {:registered, self()})
        harness_loop(reply_fn)
      end)

    assert_receive {:registered, ^pid}, 2_000
    pid
  end

  defp harness_loop(reply_fn) do
    receive do
      {:"$gen_call", from, {verb, %{}}} ->
        reply_fn.(verb, from)
        harness_loop(reply_fn)
    end
  end

  defp call(tool_name, params, assigns) do
    before = Task.Supervisor.children(CodeMySpec.TaskSupervisor)
    response = ToolLibrary.run(tool_name, params, assigns)
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
