defmodule CodeMySpec.Promotion.SelfRestartTest do
  @moduledoc """
  A self-hosted promotion answers before its own restart can end the call
  that would have reported it (54aa534c, second defect).

  `just restart`, for a checkout that is this process's own booted root,
  kills the very BEAM running the promotion — not a channel drop
  (`e721ccf0d`'s own fix covers that shape, for a genuinely remote harness),
  a full VM halt with no exception to catch and no `after` block guaranteed
  to run. So the restart is dispatched detached, and `promote/1` answers
  with the same "unconfirmed" shape a dropped channel already produces,
  before the detached task's own restart has a chance to run at all.

  `:persistent_term` is node-global, so the boot root one test writes is the
  one every other test reads — `CodeMySpec.BootVersionTest` carries the same
  note for the same reason. Async: false, and cleaned up in `on_exit`.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.BootVersion
  alias CodeMySpec.Promotion
  alias CodeMySpec.WorkingCopies

  setup do
    on_exit(fn -> :persistent_term.erase({BootVersion, :boot}) end)
    :ok
  end

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
  # a promotion. The restart recipe writes a marker rather than doing
  # anything that resembles a real restart: this project's own dev server
  # must never be touched by a test.
  defp a_promotable_project do
    running_root = CodeMySpec.TempFile.dir("self-restart-running")
    init_repo(running_root)
    File.write!(Path.join(running_root, "app.ex"), "defmodule App do\nend\n")

    File.write!(Path.join(running_root, "justfile"), """
    restart:
        @date > {{justfile_directory()}}/.restarted
    """)

    git!(running_root, ["add", "-A"])
    git!(running_root, ["commit", "-q", "-m", "base"])

    agent_root = CodeMySpec.TempFile.dir("self-restart-agent")
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

  test "reports merged-and-unconfirmed instead of trying to answer after its own restart" do
    scope = full_scope_fixture()
    {running_root, agent_root} = a_promotable_project()

    {:ok, running} =
      WorkingCopies.issue(scope, nil,
        label: "the checkout the dev app runs in",
        device: device_fixture(scope)
      )

    # `issue/3` mints before any root is known; `report_root/2` is the
    # separate claim that also designates the project's first checkout as
    # main, matching a real harness's own join.
    {:ok, running} = WorkingCopies.report_root(running, running_root)

    {:ok, agent} =
      WorkingCopies.issue(scope, nil,
        label: "the coding agent's copy",
        device: device_fixture(scope)
      )

    {:ok, agent} = WorkingCopies.report_root(agent, agent_root)

    File.write!(Path.join(agent_root, "app.ex"), "defmodule App do\n  def changed, do: true\nend\n")
    git!(agent_root, ["commit", "-qam", "the story's work"])

    scope = %{scope | active_working_copy_id: agent.id}
    :ok = analyzers_are_current(scope, running)

    # The premise: this process booted from the same checkout the promotion
    # is about to restart, matching this project's own self-hosted setup.
    BootVersion.capture(running_root)

    result = Promotion.promote(scope)

    assert {:ok, %{merged: "story/x", serving: %{revision: nil, unconfirmed: reason}}} = result,
           "a self-hosted promotion has to report merged-and-unconfirmed, not try " <>
             "to run the restart inline and hope the process survives to answer. " <>
             "Got: #{inspect(result)}"

    assert Promotion.restart_acknowledgement_lost?(reason),
           "the reason a self-restart reports has to be recognised by the same " <>
             "predicate a dropped remote channel is, since both mean the same " <>
             "thing to a caller: merged, restart unconfirmed, do not promote " <>
             "again to find out. Got: #{inspect(reason)}"

    # The restart still has to actually happen — dispatched, not skipped.
    # Polled rather than asserted immediately: it runs in a detached task
    # precisely so this process's own answer does not wait on it.
    assert eventually(fn -> File.exists?(Path.join(running_root, ".restarted")) end),
           "the detached restart never ran — self-hosting detection must not " <>
             "also skip doing the restart, only skip waiting for it"

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
