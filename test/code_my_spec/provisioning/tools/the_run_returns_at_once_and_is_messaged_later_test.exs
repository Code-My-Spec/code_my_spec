defmodule CodeMySpec.Provisioning.Tools.TheRunReturnsAtOnceAndIsMessagedLaterTest do
  @moduledoc """
  Issue 4f7929e4, batch 1: this tool used to call
  `Steps.provision_account_server/3` synchronously -- real box creation,
  network attach, SSH boot wait, registry and database container checks --
  inside the code-mode sandbox's 30s wall clock. Same lock-then-ack handshake
  `run_provisioning_step` already uses (see
  `a_finished_step_wakes_its_starter_test.exs`): the spawned task claims
  `RunLock` first and only then acks, so the caller learns "started" in
  milliseconds and is messaged the outcome once the run lands.

  Real provider calls stay off: `Req.Test.stub(Hetzner, ...)` refuses
  everything, reached automatically inside the spawned task through
  `$callers` (`Task.Supervisor.start_child/2` sets it, the same way
  `RunLock.caller_run_id/1` already relies on) -- no real Hetzner box is
  created or billed.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Servers.Server
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures

  setup do
    previous_async = Application.get_env(:code_my_spec, :provisioning_run_async)
    Application.put_env(:code_my_spec, :provisioning_run_async, true)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_run_async, previous_async)
    end)

    # The run spawns a detached task, which checks out its own connection.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)

    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")

    {:ok, _} =
      AccountSecrets.put_value(
        scope,
        "server_ssh_public_key",
        "ssh-ed25519 AAAAfake test-fixture"
      )

    {:ok, _} =
      AccountSecrets.put_value(
        scope,
        "server_ssh_private_key",
        "-----BEGIN FAKE KEY-----\nfixture\n-----END FAKE KEY-----\n"
      )

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

  test "the agent that started the run is told how it ended", %{scope: scope, agent: agent} do
    Req.Test.stub(Hetzner, &refuse/1)

    {response, task_pids} = call(%{scope: scope, agent_id: agent.id})

    assert response_text(response) =~ "is starting"
    assert response_text(response) =~ "you'll be messaged how it ends"
    refute response_text(response) =~ "Could not bring up"

    assert Server.get_linked(scope, "acme-box"),
           "expected the name linked synchronously, before the async run even started"

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
    assert message =~ "Could not bring up acme-box"

    await(task_pids)
  end

  test "a caller with no agent is told to call this tool again, not to watch devops_status", %{
    scope: scope
  } do
    Req.Test.stub(Hetzner, &refuse/1)

    {response, task_pids} = call(%{scope: scope})

    assert response_text(response) =~ "call this tool again"
    refute response_text(response) =~ "devops_status"

    await(task_pids)
    refute_received {:agent_dispatch, _, _, _}
  end

  defp call(assigns) do
    before = Task.Supervisor.children(CodeMySpec.TaskSupervisor)
    response = ToolLibrary.run("provision_account_server", %{name: "acme-box"}, assigns)
    {response, Task.Supervisor.children(CodeMySpec.TaskSupervisor) -- before}
  end

  defp await(pids) do
    for pid <- pids do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp refuse(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      401,
      Jason.encode!(%{
        "error" => %{"code" => "unauthorized", "message" => "unable to authenticate"}
      })
    )
  end

  defp response_text({_status, text}), do: text
end
