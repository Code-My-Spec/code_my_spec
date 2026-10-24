defmodule CodeMySpec.Provisioning.Tools.AdoptingARepositoryReturnsAtOnceAndIsMessagedLaterTest do
  @moduledoc """
  Issue 4f7929e4, batch 1: `adopt_repository` held `RunLock` and waited for
  the real git push inline, on the stated bet that "a push is seconds, not
  minutes" -- a considered bet, not a guarantee, and one that put a slow
  network, a large repository, or a GitHub hiccup inside the code-mode
  sandbox's 30s wall clock. Same lock-then-ack handshake `run_provisioning_step`
  already uses (see `a_finished_step_wakes_its_starter_test.exs`).

  A local bare repo stands in for GitHub's remote the same way
  `adopt_repository_test.exs` already does -- the push is real, the network
  call is not.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.GitHub
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    previous_async = Application.get_env(:code_my_spec, :provisioning_run_async)
    Application.put_env(:code_my_spec, :provisioning_run_async, true)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_run_async, previous_async)
    end)

    # The run spawns a detached task, which checks out its own connection.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    working_dir = CodeMySpec.TempFile.owned_dir("adopt_repository_async_working")
    File.write!(Path.join(working_dir, "README.md"), "# market_my_spec\n")

    bare_dir = CodeMySpec.TempFile.owned_dir("adopt_repository_async_bare")
    {_, 0} = System.cmd("git", ["init", "--bare", "-b", "main", bare_dir])

    scope = full_scope_fixture()
    _ = github_integration_fixture(scope.user)
    scope = put_fixture_execution_context(scope, ExecutionContext.new(:local, working_dir))

    RecordingAgentTransport.listen(scope)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        status: :running,
        working_copy: working_dir,
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    %{scope: scope, agent: agent, project: scope.active_project, bare_dir: bare_dir}
  end

  test "returns as soon as the run starts, and the agent is told how it ended", %{
    scope: scope,
    agent: agent,
    project: project,
    bare_dir: bare_dir
  } do
    stub_github(fn
      %{method: "GET", request_path: "/user"} = conn ->
        json(conn, 200, %{"login" => "johns10"})

      %{method: "GET", request_path: "/repos/johns10/market_my_spec"} = conn ->
        json(conn, 200, %{"name" => "market_my_spec", "clone_url" => bare_dir})

      %{method: "POST"} = conn ->
        flunk("created a repository instead of adopting the real one")
        conn
    end)

    {response, task_pids} = call(%{scope: scope, agent_id: agent.id})

    assert response_text(response) =~ "Adopting market_my_spec"
    assert response_text(response) =~ "you'll be messaged how it ends"

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
    assert message =~ "Adopted market_my_spec for #{project.name}"
    assert message =~ "repository step is now"

    assert {log, 0} = System.cmd("git", ["log", "--oneline"], cd: bare_dir)
    assert log != ""

    await(task_pids)
  end

  test "a caller with no agent is told to watch devops_status instead", %{
    scope: scope,
    bare_dir: bare_dir
  } do
    stub_github(fn
      %{method: "GET", request_path: "/user"} = conn ->
        json(conn, 200, %{"login" => "johns10"})

      %{method: "GET", request_path: "/repos/johns10/market_my_spec"} = conn ->
        json(conn, 200, %{"name" => "market_my_spec", "clone_url" => bare_dir})

      %{method: "POST"} = conn ->
        flunk("created a repository instead of adopting the real one")
        conn
    end)

    {response, task_pids} = call(%{scope: scope})

    assert response_text(response) =~ "devops_status"

    await(task_pids)
    refute_received {:agent_dispatch, _, _, _}
  end

  defp stub_github(fun), do: Req.Test.stub(GitHub, fun)

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp call(assigns) do
    before = Task.Supervisor.children(CodeMySpec.TaskSupervisor)
    response = ToolLibrary.run("adopt_repository", %{repository_name: "market_my_spec"}, assigns)
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
