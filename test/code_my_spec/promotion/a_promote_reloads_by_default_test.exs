defmodule CodeMySpec.Promotion.APromoteReloadsByDefaultTest do
  @moduledoc """
  A promote reloads main's app by default and restarts it when the change
  needs a restart, the caller asks for one, the harness cannot reload, or the
  reload fails (John, 2026-10-02).

  The harness is a process registered in `HarnessRegistry` under main's id,
  the way `HarnessProjectChannel` registers on join, answering the app verbs
  `Promotion.Runner` sends and reporting each one to the test.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion
  alias CodeMySpec.WorkingCopies

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end

  defp a_promotable_project(files \\ %{}) do
    running_root = CodeMySpec.TempFile.dir("reload-running")
    File.mkdir_p!(running_root)
    git!(running_root, ["init", "-q", "-b", "main"])
    git!(running_root, ["config", "user.email", "spex@example.com"])
    git!(running_root, ["config", "user.name", "Spex"])
    File.mkdir_p!(Path.join(running_root, "config"))
    File.write!(Path.join(running_root, "app.ex"), "defmodule App do\nend\n")
    File.write!(Path.join(running_root, "config/config.exs"), "import Config\n")

    Enum.each(files, fn {path, content} -> File.write!(Path.join(running_root, path), content) end)

    git!(running_root, ["add", "-A"])
    git!(running_root, ["commit", "-q", "-m", "base"])

    agent_root = CodeMySpec.TempFile.dir("reload-agent")
    File.rm_rf!(agent_root)
    git!(running_root, ["worktree", "add", "-b", "story/x", agent_root, "main"])

    on_exit(fn ->
      File.rm_rf(agent_root)
      File.rm_rf(running_root)
    end)

    {running_root, agent_root}
  end

  # `replies` maps a verb to its answer; the verbs arrive at the test in order.
  defp a_harness_for(working_copy_id, running_root, opts) do
    test = self()
    replies = Keyword.fetch!(opts, :replies)

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "test-harness", running_root)

      declare_verbs(working_copy_id, Keyword.get(opts, :verbs, ["reload_app"]))
      send(test, :registered)
      answer(test, replies)
    end)

    assert_receive :registered, 2_000
  end

  defp declare_verbs(working_copy_id, verbs),
    do: Enum.each(verbs, &HarnessRegistry.register_verb(working_copy_id, &1))

  defp answer(test, replies) do
    receive do
      {:"$gen_call", from, {verb, _request}} ->
        send(test, {:app_verb, verb})
        GenServer.reply(from, Map.fetch!(replies, verb))
        answer(test, replies)
    end
  end

  defp promote_a_change(path, opts) do
    scope = full_scope_fixture()
    {running_root, agent_root} = a_promotable_project(Keyword.get(opts, :files, %{}))

    {:ok, running} =
      WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))

    {:ok, running} = WorkingCopies.report_root(running, running_root)

    :ok =
      Environments.register(
        {:working_copy, running.id},
        Environment.new(:local, running_root)
      )

    a_harness_for(running.id, running_root, opts)

    {:ok, agent} = WorkingCopies.issue(scope, nil, label: "agent", device: device_fixture(scope))
    {:ok, agent} = WorkingCopies.report_root(agent, agent_root)

    :ok =
      Environments.register(
        {:working_copy, agent.id},
        Environment.new(:local, agent_root)
      )

    File.write!(Path.join(agent_root, path), "# changed\n")
    git!(agent_root, ["commit", "-qam", "the work"])

    scope = %{scope | active_working_copy_id: agent.id}
    head = agent_root |> git!(["rev-parse", "HEAD"]) |> String.trim()
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: head)

    result = Promotion.promote(scope, nil, Keyword.get(opts, :promote, []))
    send(self(), {:running_root, running_root})
    result
  end

  defp head_commit_files do
    assert_received {:running_root, root}
    {root, root |> git!(["show", "--name-only", "--format=", "HEAD"]) |> String.split()}
  end

  @serving {:ok, %{status: "serving", url: "http://127.0.0.1:4000", commit: "launch0"}}
  @reloaded {:ok,
             %{
               status: "serving",
               url: "http://127.0.0.1:4000",
               commit: "launch0",
               serving_commit: "reload1",
               action: "reloaded"
             }}

  test "a change a reload can take is reloaded, not restarted" do
    result = promote_a_change("app.ex", replies: %{reload_app: @reloaded, restart_app: @serving})

    assert {:ok, %{merged: "story/x", deployment: %{action: :reload, reason: reason}}} = result
    assert reason =~ "nothing in the change needs a restart"
    assert Promotion.outcome_text(result) =~ "reload"

    assert_receive {:app_verb, :reload_app}, 2_000
    refute_receive {:app_verb, :restart_app}, 200
  end

  describe "the version a promote originates" do
    test "is a tag, not a mix.exs commit, so it is no reason to restart" do
      result =
        promote_a_change("app.ex",
          files: %{
            "mix.exs" =>
              ~s(defmodule App.MixProject do\n  def project, do: [version: "0.1.0"]\nend\n)
          },
          replies: %{reload_app: @reloaded, restart_app: @serving}
        )

      assert {:ok, %{version: "0.1.1", deployment: %{action: :reload}}} = result
      {_root, files} = head_commit_files()

      assert files == ["app.ex"],
             "main's HEAD is the promoted commit; nothing is committed on top"

      assert_receive {:app_verb, :reload_app}, 2_000
    end
  end

  test "a change to config restarts, and says which path made it" do
    result =
      promote_a_change("config/config.exs",
        replies: %{reload_app: @reloaded, restart_app: @serving}
      )

    assert {:ok, %{deployment: %{action: :restart, reason: reason}}} = result
    assert reason =~ "config/config.exs"

    assert_receive {:app_verb, :restart_app}, 2_000
    refute_received {:app_verb, :reload_app}
  end

  test "restart: true restarts whatever the change" do
    result =
      promote_a_change("app.ex",
        replies: %{reload_app: @reloaded, restart_app: @serving},
        promote: [restart: true]
      )

    assert {:ok, %{deployment: %{action: :restart, reason: "a restart was asked for"}}} = result
    assert_receive {:app_verb, :restart_app}, 2_000
  end

  test "a harness that never declared reload_app is restarted" do
    result =
      promote_a_change("app.ex", replies: %{restart_app: @serving}, verbs: [])

    assert {:ok, %{deployment: %{action: :restart, reason: reason}}} = result
    assert reason =~ "predates reloads"
    assert_receive {:app_verb, :restart_app}, 2_000
  end

  test "a failed reload falls back to a restart in the same promote" do
    promote_a_change("app.ex",
      replies: %{
        reload_app: {:error, {:reload_failed, "`just reload` failed (1): migration blew up"}},
        restart_app: @serving
      }
    )

    assert_receive {:app_verb, :reload_app}, 2_000
    assert_receive {:app_verb, :restart_app}, 2_000
  end

  test "deployment_plan reads an unreadable diff as a restart" do
    assert %{action: :restart} = Promotion.deployment_plan(nil)
    assert %{action: :reload} = Promotion.deployment_plan([])
    assert %{action: :restart} = Promotion.deployment_plan(["lib/x.ex"], reload_supported: false)
  end
end
