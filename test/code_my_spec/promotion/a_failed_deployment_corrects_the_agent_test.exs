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

  So this drives a restart that fails outright — the running copy answers the
  app verb with the app down, which is neither a lost acknowledgement nor
  ambiguous — and asserts the agent is told, through the delivery path rather
  than through a log line.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  import Phoenix.ChannelTest

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Files
  alias CodeMySpec.Promotion
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    # The correction is sent from the detached restart task, which checks out
    # its own connection.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    :ok
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end

  # The same two-checkout shape the async-deployment test uses, with the one
  # difference that is the whole point: the restart fails.
  #
  # The failure arrives on the running copy's own channel, which is the seam
  # `Runner.restart/3` actually uses. A justfile recipe cannot fail a restart
  # any more, and a copy with no harness at all fails for a different reason.
  defp a_project_whose_restart_fails do
    running_root = CodeMySpec.TempFile.dir("failed-restart-running")
    File.mkdir_p!(running_root)
    git!(running_root, ["init", "-q", "-b", "main"])
    git!(running_root, ["config", "user.email", "spex@example.com"])
    git!(running_root, ["config", "user.name", "Spex"])
    File.write!(Path.join(running_root, "app.ex"), "defmodule App do\nend\n")

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

  # The running copy joins, so `AppTransport.restart_app/2` has a channel to
  # reach. The join is what issues the working copy — with the device it
  # announces from and the root it serves — so this replaces the plain
  # `a_copy/3` the running checkout used to get: two joins on one copy are
  # refused, and correctly so.
  defp the_running_copy_joins(context, running_root) do
    {:ok, reply, socket} =
      UserSocket
      |> socket("failed-restart-running", %{scope: context.scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{context.project.id}",
        %{
          "root" => running_root,
          "label" => "the checkout the dev app runs in",
          "device" => %{"id" => device_fixture(context.scope).id},
          "app_verbs" => ["reload_app"]
        }
      )

    {reply, socket}
  end

  # Answer one app verb the way a copy whose app came back down does. An
  # `app_status` other than `"serving"` decodes to `{:error, ...}` in
  # `Runner.decode_app_result/1` — neither a lost acknowledgement nor a
  # timeout, so it classifies as a genuine failure.
  defp answer_app_down(socket, verb) do
    assert_push ^verb, %{"ref" => ref}, 5_000

    reply_ref =
      push(socket, verb <> "_result", %{
        "ref" => ref,
        "status" => "ok",
        "app_status" => "down",
        "app_url" => nil,
        "app_commit" => nil
      })

    receive do
      %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
    after
      1_000 -> flunk("#{verb}_result was never acknowledged")
    end
  end

  defp a_story_with_linked_spex(scope) do
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

    story
  end

  defp a_copy(scope, root, label) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: label, device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, root)
    copy
  end

  test "a restart that really failed is retracted to the agent that was told QA could start" do
    scope = full_scope_fixture()
    # The scope's own project, not a second one minted beside it: the join
    # issues the running copy into whichever project its payload names, and a
    # promotion reads `main` off the scope's project. Two different projects
    # here means the running copy joins into one nothing is looking at.
    context = %{scope: scope, project: scope.active_project}

    {running_root, agent_root} = a_project_whose_restart_fails()

    # The running copy joins first and so is the project's first checkout —
    # which is what designates it main. Promote merges into main, so a running
    # copy minted after the agent's would leave the promotion aimed at the
    # agent's own worktree and nothing here would mean what it says.
    {_running_reply, running_socket} = the_running_copy_joins(context, running_root)

    agent_copy = a_copy(scope, agent_root, "the coding agent's copy")

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
    story = a_story_with_linked_spex(scope)
    head = agent_root |> git!(["rev-parse", "HEAD"]) |> String.trim()
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: head)

    assert {:ok, %{merged: "story/x"}} =
             Promotion.promote(scope, story.number, notify: agent.id)

    # The promotion's own reload/restart is answered down on the running copy's
    # channel: this is the failed deployment the correction is about.
    answer_app_down(running_socket, "reload_app")
    answer_app_down(running_socket, "restart_app")

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
