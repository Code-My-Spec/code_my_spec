defmodule CodeMySpec.Promotion.AConfirmedRestartReachesTheAgentTest do
  @moduledoc """
  `promote` answers "restart dispatched, not yet confirmed". An in-app agent
  that decides to wait for the confirmation has to be told when it arrives —
  on metric_flow (2026-09-27) it only reached web.log and the agent sat idle.

  Driven through the `promote` tool, because the agent id lives on the tool
  call's frame: that is the only place that knows who received the first
  answer.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Files
  alias CodeMySpec.McpServers.Promotion.Tools.Promote
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    # The message is sent from the detached restart task.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    :ok
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end

  defp a_project_whose_restart_succeeds do
    running_root = CodeMySpec.TempFile.dir("confirmed-restart-running")
    File.mkdir_p!(running_root)
    git!(running_root, ["init", "-q", "-b", "main"])
    git!(running_root, ["config", "user.email", "spex@example.com"])
    git!(running_root, ["config", "user.name", "Spex"])
    File.write!(Path.join(running_root, "app.ex"), "defmodule App do\nend\n")

    File.write!(Path.join(running_root, "justfile"), """
    restart:
        @echo "up"
    """)

    git!(running_root, ["add", "-A"])
    git!(running_root, ["commit", "-q", "-m", "base"])

    agent_root = CodeMySpec.TempFile.dir("confirmed-restart-agent")
    File.rm_rf!(agent_root)
    git!(running_root, ["worktree", "add", "-b", "story/x", agent_root, "main"])

    on_exit(fn ->
      File.rm_rf(agent_root)
      File.rm_rf(running_root)
    end)

    {running_root, agent_root}
  end

  defp a_copy(scope, root, label) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: label, device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, root)
    copy
  end

  defp ready_to_promote do
    scope = full_scope_fixture()
    {running_root, agent_root} = a_project_whose_restart_succeeds()

    a_copy(scope, running_root, "the checkout the dev app runs in")
    agent_copy = a_copy(scope, agent_root, "the coding agent's copy")

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: agent_root,
        working_copy_id: agent_copy.id
      })

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
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: head)

    {scope, agent, running_root, %{story_number: story.number}}
  end

  test "a confirmed restart is messaged to the agent that called promote" do
    {scope, agent, running_root, params} = ready_to_promote()
    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    assert {:reply, _response, _frame} = Promote.execute(params, frame)

    agent_id = agent.id

    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 30_000, """
    The restart was confirmed and nothing reached the agent. It was told
    "dispatched, not yet confirmed" and has no other way to learn the outcome.
    """

    assert message =~ "confirmed"
    assert message =~ running_root

    assert settled?()
  end

  test "a promote with no agent behind it messages nobody" do
    {scope, _agent, _running_root, params} = ready_to_promote()
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:reply, _response, _frame} = Promote.execute(params, frame)

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
