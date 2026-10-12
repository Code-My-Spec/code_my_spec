defmodule CodeMySpec.Promotion.AConfirmedRestartReachesTheAgentTest do
  @moduledoc """
  A queued story promotion reports a confirmed restart with the originating
  agent's identity. Once the story has landed, confirmation is informational:
  an agent without an open promotion task must not receive another work turn.

  Driven through the promote tool to cover caller identity propagation across
  the queue and the detached deployment. PromotionNoticeRoutingTest covers
  delivery to agents that still hold an open promotion task.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.QaFixtures
  import CodeMySpecTest.PromotionQueueHelpers
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.McpServers.Promotion.Tools.Promote
  alias CodeMySpec.PromotionQueue.Worker
  alias CodeMySpec.TempFile
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    test = self()
    handler = {__MODULE__, test}

    :ok =
      :telemetry.attach(
        handler,
        [:code_my_spec, :promotion, :report],
        fn _event, _measurements, meta, _config ->
          send(test, {:promotion_report, meta.agent_id, meta.what, meta.text, self()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The message is sent from the detached restart task.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    :ok
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end

  defp a_project_whose_restart_succeeds do
    running_root = TempFile.dir("confirmed-restart-running")
    File.mkdir_p!(running_root)
    git!(running_root, ["init", "-q", "-b", "main"])
    git!(running_root, ["config", "user.email", "spex@example.com"])
    git!(running_root, ["config", "user.name", "Spex"])
    File.write!(Path.join(running_root, "app.ex"), "defmodule App do\nend\n")

    git!(running_root, ["add", "-A"])
    git!(running_root, ["commit", "-q", "-m", "base"])

    agent_root = TempFile.dir("confirmed-restart-agent")
    File.rm_rf!(agent_root)
    git!(running_root, ["worktree", "add", "-b", "story/x", agent_root, "main"])

    # The promotion queue's gate copy: the batch is built and gated here.
    gate_root = TempFile.dir("confirmed-restart-gate")
    File.rm_rf!(gate_root)
    git!(running_root, ["worktree", "add", "--detach", gate_root, "main"])

    on_exit(fn ->
      File.rm_rf(gate_root)
      File.rm_rf(agent_root)
      File.rm_rf(running_root)
    end)

    {running_root, agent_root, gate_root}
  end

  defp a_copy(scope, root, label) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: label, device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, root)

    :ok =
      Environments.register(
        {:working_copy, copy.id},
        Environment.new(:local, root)
      )

    copy
  end

  # Restart uses the working copy's registered app transport, not its justfile.
  defp a_running_harness(copy, commit) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = HarnessRegistry.register_executor(copy.id, "test-harness", copy.root)
        send(test, :harness_registered)

        receive do
          {:"$gen_call", from, {:restart_app, _request}} ->
            GenServer.reply(from, {:ok, %{status: "serving", url: "http://test", commit: commit}})
            send(test, :restart_served)

          :stop ->
            :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    assert_receive :harness_registered, 2_000
  end

  defp ready_to_promote do
    scope = full_scope_fixture()
    {running_root, agent_root, gate_root} = a_project_whose_restart_succeeds()

    running_copy = a_copy(scope, running_root, "the checkout the dev app runs in")
    agent_copy = a_copy(scope, agent_root, "the coding agent's copy")
    gate_copy = a_copy(scope, gate_root, Worker.gate_label())
    on_exit(fn -> stop_worker(scope.active_project_id) end)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: agent_root,
        working_copy_id: agent_copy.id
      })

    AgentPresence.present(agent)

    File.write!(
      Path.join(agent_root, "app.ex"),
      "defmodule App do\n  def changed, do: true\nend\n"
    )

    git!(agent_root, ["commit", "-qam", "the story's work"])

    scope = %{scope | active_working_copy_id: agent_copy.id}
    story = story_fixture(scope)

    {_n, _} =
      Files.upsert_files(scope, [
        %{
          path: "test/spex/#{story.number}_x/criterion_1_spex.exs",
          role: :bdd_spec,
          story_id: story.id,
          valid: true,
          mtime: DateTime.utc_now()
        }
      ])

    head = agent_root |> git!(["rev-parse", "HEAD"]) |> String.trim()
    a_running_harness(running_copy, head)

    story
    |> Ecto.Changeset.change(qa_ready_commit: head, qa_ready_at: DateTime.utc_now())
    |> CodeMySpec.Repo.update!()

    {:ok, _} = passed_qa_attempt(scope, story_id: story.id)

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: head)

    # A lone candidate level with main is its own batch commit, gated there.
    AnalysisFixtures.fresh_analysis_runs_fixture(
      %{scope | active_working_copy_id: gate_copy.id},
      Run.sources(),
      commit: head
    )

    {scope, agent, running_root, %{story_number: story.number}}
  end

  test "a confirmed restart retains caller identity without waking a free agent" do
    {scope, agent, running_root, params} = ready_to_promote()
    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    assert {:reply, _response, _frame} = Promote.execute(params, frame)
    assert_receive :restart_served, 5_000

    agent_id = agent.id

    assert_receive {:promotion_report, ^agent_id, "restart confirmation", message, deployment},
                   5_000

    # All synchronous telemetry handlers must finish before checking suppression.
    monitor = Process.monitor(deployment)
    assert_receive {:DOWN, ^monitor, :process, ^deployment, _reason}, 5_000
    assert message =~ "from your promotion is confirmed:"
    assert message =~ running_root
    assert settled?()

    # Story landing frees the team; only an open promotion task may receive
    # a confirmation. Failures still follow their separate correction path.
    refute_received {:agent_dispatch, ^agent_id, _ref, ^message}
  end

  test "a promote with no agent behind it messages nobody" do
    {scope, _agent, _running_root, params} = ready_to_promote()
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:reply, _response, _frame} = Promote.execute(params, frame)
    assert_receive :restart_served, 5_000

    assert settled?()
    refute_received {:agent_dispatch, _, _, _}
  end

  defp settled?(remaining \\ 100)
  defp settled?(0), do: false

  defp settled?(remaining),
    do: still_working(Task.Supervisor.children(CodeMySpec.TaskSupervisor), remaining)

  defp still_working([], _remaining), do: true

  defp still_working(_children, remaining) do
    Process.sleep(50)
    settled?(remaining - 1)
  end
end
