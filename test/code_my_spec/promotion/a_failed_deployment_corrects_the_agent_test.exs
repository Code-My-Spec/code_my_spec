defmodule CodeMySpec.Promotion.AFailedDeploymentCorrectsTheAgentTest do
  @moduledoc """
  The half of `2a212eb0`'s fix that had no test: a real restart failure still
  corrects the agent.

  `promote/2` answers as soon as the merge lands, which means it has already
  told the agent "merged, QA can start" by the time the detached restart
  resolves. When that restart genuinely fails, the earlier message is wrong and
  only a correction retracts it — otherwise the agent proceeds on the last thing
  it was told, and the only record is a `Logger.error` nobody is tailing.

  `correct_the_agent/4` then learned to stay quiet when the failure is a *lost
  acknowledgement* rather than a failed restart (`restart_acknowledgement_lost?/1`
  — a dropped channel, a `promotion_restart` RPC timeout), because correcting
  there tells an agent to promote again over a restart that already succeeded,
  and every retry restarts the shared dev server. QA found that and it was fixed;
  the fix shipped with nothing covering this path at all, and the risk it carries
  runs this way: an early return that swallows real failures too.

  So this drives a restart that fails outright — a recipe that exits non-zero,
  which is neither a lost acknowledgement nor ambiguous — and asserts the agent
  is told, through the delivery path rather than through a log line.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Promotion
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    # The correction is sent from the detached restart task, which checks out
    # its own connection.
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    :ok
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end

  # The same two-checkout shape the async-deployment test uses, with the one
  # difference that is the whole point: the restart recipe fails.
  defp a_project_whose_restart_fails do
    running_root = CodeMySpec.TempFile.dir("failed-restart-running")
    File.mkdir_p!(running_root)
    git!(running_root, ["init", "-q", "-b", "main"])
    git!(running_root, ["config", "user.email", "spex@example.com"])
    git!(running_root, ["config", "user.name", "Spex"])
    File.write!(Path.join(running_root, "app.ex"), "defmodule App do\nend\n")

    File.write!(Path.join(running_root, "justfile"), """
    restart:
        @echo "the migration blew up" && exit 1
    """)

    git!(running_root, ["add", "-A"])
    git!(running_root, ["commit", "-q", "-m", "base"])

    agent_root = CodeMySpec.TempFile.dir("failed-restart-agent")
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

  test "a restart that really failed is retracted to the agent that was told QA could start" do
    scope = full_scope_fixture()
    {running_root, agent_root} = a_project_whose_restart_fails()

    running = a_copy(scope, running_root, "the checkout the dev app runs in")
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
    AnalysisFixtures.fresh_analysis_runs_fixture(scope)
    AnalysisFixtures.fresh_analysis_runs_fixture(%{scope | active_working_copy_id: running.id})

    assert {:ok, %{merged: "story/x"}} = Promotion.promote(scope, notify: agent.id)

    agent_id = agent.id

    assert_receive {:agent_dispatch, ^agent_id, _ref, correction}, 30_000, """
    The restart failed outright and nothing reached the agent. It is still
    holding "merged, QA can start", which is now false. This is the direction
    2a212eb0's fix could break: the early return for a lost acknowledgement
    must not swallow a restart that genuinely failed.
    """

    assert correction =~ "Correction on the promotion"

    assert correction =~ "Nothing was rolled back", """
    The correction has to say the merge is still on the running copy. Without
    it the natural reading of "the deployment failed" is that the merge came
    back out, and an agent that believes that promotes the same work twice.
    """

    # The message arrives before the task that sent it has finished, and the
    # rest of that task still writes. Without waiting, teardown pulls the
    # sandbox connection out from under it and the run carries a crash report
    # for work that succeeded.
    assert settled?()
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
