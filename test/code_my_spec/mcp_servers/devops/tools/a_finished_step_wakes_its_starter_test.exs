defmodule CodeMySpec.McpServers.Devops.Tools.AFinishedStepWakesItsStarterTest do
  @moduledoc """
  1599c109: metric_flow's main agent started a UAT deploy, ended its turn as
  told, and sat idle eleven minutes after the step finished because nothing
  told it. The agent that started a step is messaged its outcome.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Devops.Tools.RunProvisioningStep
  alias CodeMySpec.Projects
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    previous_transport = Application.get_env(:code_my_spec, :agent_transport)
    previous_async = Application.get_env(:code_my_spec, :provisioning_run_async)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    Application.put_env(:code_my_spec, :provisioning_run_async, true)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :agent_transport, previous_transport)
      Application.put_env(:code_my_spec, :provisioning_run_async, previous_async)
    end)

    RecordingAgentTransport.listen()
    # The step runs in a detached task, which checks out its own connection.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    {:ok, working_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, working_dir)}
    {:ok, _} = Projects.update_project(scope, scope.active_project, %{domain: "example.com"})

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        status: :running,
        working_copy: working_dir,
        working_copy_id: scope.active_working_copy_id
      })

    %{scope: scope, agent: agent}
  end

  # Paused without a provider call: the probe address is off the domain.
  @params %{step: "inbound", inbound_probe_to: "sam@somewhere-else.com"}

  test "the agent that started a step is told how it ended", %{scope: scope, agent: agent} do
    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    {response, step_tasks} = run_step(frame)
    assert response_text(response) =~ "you'll be messaged how it ends"

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
    assert message =~ "inbound"
    assert message =~ "paused"
    assert message =~ "sam@somewhere-else.com is not on example.com"

    await(step_tasks)
  end

  test "a caller with no agent is told to watch devops_status instead", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    {response, step_tasks} = run_step(frame)
    assert response_text(response) =~ "devops_status"

    await(step_tasks)
    refute_received {:agent_dispatch, _, _, _}
  end

  describe "outcome_message/3" do
    test "done" do
      assert RunProvisioningStep.outcome_message({:ok, %{state: :done}}, "deploy (uat)", "MF") =~
               "Your deploy (uat) step for MF finished: done."
    end

    test "errored carries the error" do
      text =
        RunProvisioningStep.outcome_message(
          {:halt, %{state: :errored}, "docker build failed"},
          "deploy (uat)",
          "MF"
        )

      assert text =~ "Your deploy (uat) step for MF errored: docker build failed"
    end
  end

  # The step and its delivery run in a detached task; waiting for it keeps
  # the task from outliving the test's sandbox.
  defp run_step(frame) do
    before = Task.Supervisor.children(CodeMySpec.TaskSupervisor)
    assert {:reply, response, ^frame} = RunProvisioningStep.execute(@params, frame)
    {response, Task.Supervisor.children(CodeMySpec.TaskSupervisor) -- before}
  end

  defp await(pids) do
    for pid <- pids do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
