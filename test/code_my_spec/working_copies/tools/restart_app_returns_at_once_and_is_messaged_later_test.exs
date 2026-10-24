defmodule CodeMySpec.AppInstances.Tools.RestartAppReturnsAtOnceAndIsMessagedLaterTest do
  @moduledoc """
  Issue f2977826, batch 2 of 4f7929e4: `restart_app` raced the code-mode
  sandbox's 30s wall clock with a shrinking margin. Same lock-then-ack
  handshake `run_provisioning_step` already uses. Also covers the
  one-restart-at-a-time guarantee John asked be kept: `restart_app` is the
  sanctioned way an agent restarts its own copy, and a second restart racing
  the first's own `_build` directory is exactly the hazard `AppRunLock`
  closes -- a second call while one is in flight is told so, not started
  again.

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

  test "returns at once, and the agent is told it restarted", %{scope: scope, agent: agent} do
    start_fake_harness(scope, fn
      :restart_app, from ->
        GenServer.reply(
          from,
          {:ok, %{status: "serving", url: "http://127.0.0.1:12345", commit: "abc123"}}
        )
    end)

    {response, task_pids} = call("restart_app", %{}, %{scope: scope, agent_id: agent.id})

    assert response_text(response) =~ "Restarting"
    assert response_text(response) =~ "you'll be messaged how it ends"

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
    assert message == "Restarted -- serving abc123 at http://127.0.0.1:12345."

    await(task_pids)
  end

  test "a second call while one is in flight is told so, not started again", %{
    scope: scope,
    agent: agent
  } do
    caller = self()

    harness =
      spawn_link(fn ->
        :ok =
          HarnessRegistry.register_executor(
            scope.active_working_copy_id,
            "restart-lock-test",
            "/tmp/restart-lock-test"
          )

        send(caller, :registered)

        receive do
          {:"$gen_call", from, {:restart_app, %{}}} ->
            send(caller, :got_first_call)

            receive do
              :release ->
                GenServer.reply(
                  from,
                  {:ok, %{status: "serving", url: "http://127.0.0.1:12345", commit: "abc123"}}
                )
            end
        end
      end)

    assert_receive :registered, 2_000

    {first_response, first_task_pids} =
      call("restart_app", %{}, %{scope: scope, agent_id: agent.id})

    assert response_text(first_response) =~ "Restarting"

    assert_receive :got_first_call, 2_000

    {second_response, second_task_pids} =
      call("restart_app", %{}, %{scope: scope, agent_id: agent.id})

    assert response_text(second_response) =~ "already in progress"
    refute response_text(second_response) =~ "Restarting"

    send(harness, :release)

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
    assert message =~ "Restarted"

    await(first_task_pids)
    await(second_task_pids)
  end

  defp start_fake_harness(scope, reply_fn) do
    caller = self()

    pid =
      spawn_link(fn ->
        :ok =
          HarnessRegistry.register_executor(
            scope.active_working_copy_id,
            "restart-app-test",
            "/tmp/restart-app-test"
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
