defmodule CodeMySpec.Promotion.AsyncDeploymentTest do
  @moduledoc """
  Promote answers as soon as the merge lands; the restart is dispatched, not
  awaited (54aa534c, phase two — John: "the deployment should follow async").

  Universal now, not a special case for a self-hosted checkout. It was
  first built narrowly: `just restart`, for this project's own checkout,
  kills the very BEAM running the promotion, before it could report anything
  — no exception to catch, no `after` block guaranteed to run
  (`Promotion.Lock`'s own moduledoc already records that a server restart
  comes back with an empty lock table). Dispatching detached fixed that one
  case. This test drives the *ordinary* path instead — a checkout this
  process did not boot from — to prove the dispatch is unconditional, not
  gated on detecting self-hosting.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Promotion
  alias CodeMySpec.WorkingCopies

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end

  defp init_repo(root) do
    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "main"])
    git!(root, ["config", "user.email", "spex@example.com"])
    git!(root, ["config", "user.name", "Spex"])
  end

  # Two real checkouts sharing history, matching the shape story 1046's own
  # spex use — a promotion merging into the tree it is promoting from is not
  # a promotion. `agent_root` is a worktree of `running_root`'s own `main`,
  # so `story/x` already contains everything `running_root`'s HEAD has —
  # the fast-forward precondition holds by construction, since nothing
  # commits to `running_root`'s `main` afterward.
  #
  # The restart recipe writes a marker rather than doing anything that
  # resembles a real restart: this project's own dev server must never be
  # touched by a test.
  defp a_promotable_project do
    running_root = CodeMySpec.TempFile.dir("async-deployment-running")
    init_repo(running_root)
    File.write!(Path.join(running_root, "app.ex"), "defmodule App do\nend\n")

    File.write!(Path.join(running_root, "justfile"), """
    restart:
        @date > {{justfile_directory()}}/.restarted
    """)

    git!(running_root, ["add", "-A"])
    git!(running_root, ["commit", "-q", "-m", "base"])

    agent_root = CodeMySpec.TempFile.dir("async-deployment-agent")
    File.rm_rf!(agent_root)
    git!(running_root, ["worktree", "add", "-b", "story/x", agent_root, "main"])

    on_exit(fn ->
      File.rm_rf(agent_root)
      File.rm_rf(running_root)
    end)

    {running_root, agent_root}
  end

  defp analyzers_are_current(scope, running) do
    AnalysisFixtures.fresh_analysis_runs_fixture(scope)
    AnalysisFixtures.fresh_analysis_runs_fixture(%{scope | active_working_copy_id: running.id})
    :ok
  end

  test "reports merged-and-dispatched instead of waiting for the restart to answer" do
    scope = full_scope_fixture()
    {running_root, agent_root} = a_promotable_project()

    {:ok, running} =
      WorkingCopies.issue(scope, nil,
        label: "the checkout the dev app runs in",
        device: device_fixture(scope)
      )

    {:ok, running} = WorkingCopies.report_root(running, running_root)

    {:ok, agent} =
      WorkingCopies.issue(scope, nil,
        label: "the coding agent's copy",
        device: device_fixture(scope)
      )

    {:ok, agent} = WorkingCopies.report_root(agent, agent_root)

    File.write!(
      Path.join(agent_root, "app.ex"),
      "defmodule App do\n  def changed, do: true\nend\n"
    )

    git!(agent_root, ["commit", "-qam", "the story's work"])

    scope = %{scope | active_working_copy_id: agent.id}
    :ok = analyzers_are_current(scope, running)

    result = Promotion.promote(scope)

    assert {:ok, %{merged: "story/x", serving: %{unconfirmed: reason}}} = result,
           "an ordinary promotion has to answer merged-and-dispatched, not wait " <>
             "for the restart to confirm itself. Got: #{inspect(result)}"

    assert Promotion.restart_acknowledgement_lost?(reason),
           "the dispatched-restart reason has to be recognised by the same " <>
             "predicate a dropped remote channel or a self-restart is, since all " <>
             "three mean the same thing to a caller: merged, restart unconfirmed, " <>
             "do not promote again to find out. Got: #{inspect(reason)}"

    # The restart still has to actually happen — dispatched, not skipped.
    # Polled rather than asserted immediately: it runs in a detached task
    # precisely so this call's own answer does not wait on it.
    assert eventually(fn -> File.exists?(Path.join(running_root, ".restarted")) end),
           "the detached restart never ran — answering early must not also skip " <>
             "doing the restart, only skip waiting for it"

    merged_content = File.read!(Path.join(running_root, "app.ex"))

    assert merged_content =~ "changed",
           "the merge itself has to have landed on the running copy regardless " <>
             "of what its restart does afterward"
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    fun.() or retry_eventually(fun, attempts)
  end

  defp retry_eventually(fun, attempts) do
    Process.sleep(20)
    eventually(fun, attempts - 1)
  end
end
