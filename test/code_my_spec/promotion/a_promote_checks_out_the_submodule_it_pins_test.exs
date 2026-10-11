defmodule CodeMySpec.Promotion.APromoteChecksOutTheSubmoduleItPinsTest do
  @moduledoc """
  f403faa7: a promote that moves main's `.code_my_spec` gitlink must also move
  main's submodule checkout to it, fetched from the promoting copy's submodule,
  or refuse before restarting onto a stale docs tree.

  Git is scripted through the in-memory environment's per-env shell; nothing
  shells out.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.QaFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Environments
  alias CodeMySpec.Files
  alias CodeMySpec.Promotion
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.WorkingCopies

  @main "/promote-submodule/main"
  @agent "/promote-submodule/agent"
  @sub @main <> "/.code_my_spec"
  @base "1111111111111111111111111111111111111111"
  @merged "2222222222222222222222222222222222222222"
  @old_pin "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @new_pin "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @moved "3333333333333333333333333333333333333333"

  # Everything a promotion asks git, answered as a clean fast-forward from
  # `@base` to `@merged`. `overrides` replaces single answers by `{cd, args}`.
  defp script(overrides) do
    test = self()

    fn "git", args, opts ->
      cd = Keyword.fetch!(opts, :cd)
      send(test, {:git, cd, args})
      Map.get_lazy(overrides, {cd, args}, fn -> answer(cd, args) end)
    end
  end

  defp answer(@agent, ["merge-base", "--is-ancestor", @base, "HEAD"]), do: {"", 0}
  defp answer(@agent, ["status" | _]), do: {"", 0}
  defp answer(@agent, ["rev-parse", "--abbrev-ref", "HEAD"]), do: {"story/x\n", 0}
  defp answer(@agent, ["rev-parse", "HEAD"]), do: {@merged <> "\n", 0}
  defp answer(@agent, ["ls-files" | _]), do: {"", 0}
  defp answer(@main, ["rev-parse", "HEAD"]), do: {head() <> "\n", 0}
  defp answer(@main, ["diff" | _]), do: {"", 0}
  defp answer(@main, ["merge", "--ff-only", @merged]), do: {"Fast-forward\n", 0}
  defp answer(@main, ["show", "HEAD:mix.exs"]), do: {"fatal: no mix.exs", 128}

  defp answer(@main, ["ls-tree", @base, "--", ".code_my_spec"]), do: gitlink(@old_pin)
  defp answer(@main, ["ls-tree", @merged, "--", ".code_my_spec"]), do: gitlink(@new_pin)

  defp answer(@main, ["reset", "--keep", @base]), do: {"", 0}
  defp answer(@sub, ["rev-parse", "--show-superproject-working-tree"]), do: {@main <> "\n", 0}
  defp answer(@sub, ["cat-file", "-e", @new_pin <> "^{commit}"]), do: fetched?()
  defp answer(@sub, ["fetch" | _]), do: fetch()
  defp answer(@sub, ["checkout", "--quiet", @new_pin]), do: checkout()
  defp answer(@sub, ["rev-parse", "HEAD"]), do: {current() <> "\n", 0}
  defp answer(cd, args), do: {"unscripted: git #{Enum.join(args, " ")} in #{cd}", 1}

  defp gitlink(sha), do: {"160000 commit #{sha}\t.code_my_spec\n", 0}

  # Main's HEAD: `@base` when the promoting copy is checked against it and
  # before the merge, `@merged` after, and `@moved` from the fourth read on when
  # a test has something else move main in the meantime.
  defp head do
    reads = Process.put(:head_reads, Process.get(:head_reads, 0) + 1) || 0
    Enum.at([@base, @base, @merged], reads) || Process.get(:later_head, @merged)
  end

  defp fetched?, do: {"", Process.get(:fetched_exit, 1)}

  defp fetch do
    Process.put(:fetched_exit, 0)
    {"", 0}
  end

  defp checkout do
    Process.put(:sub_head, @new_pin)
    {"", 0}
  end

  defp current, do: Process.get(:sub_head, @old_pin)

  defp a_running_harness_for(working_copy_id) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "test-harness", @main)
      send(test, :registered)

      receive do
        {:"$gen_call", from, {:restart_app, _request}} ->
          send(test, :restarted)
          GenServer.reply(from, {:ok, %{status: "serving", url: "http://x", commit: @merged}})
      end
    end)

    assert_receive :registered, 2_000
  end

  defp promote(overrides) do
    scope = full_scope_fixture()

    {:ok, running} =
      WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))

    {:ok, running} = WorkingCopies.report_root(running, @main)
    a_running_harness_for(running.id)

    {:ok, agent} = WorkingCopies.issue(scope, nil, label: "agent", device: device_fixture(scope))
    {:ok, agent} = WorkingCopies.report_root(agent, @agent)

    {:ok, env} = InMemoryEnvironment.create(shell: script(overrides))
    :ok = Environments.register({:working_copy, running.id}, env)
    :ok = Environments.register({:working_copy, agent.id}, env)
    scope = %{scope | active_working_copy_id: agent.id}

    story = story_fixture(scope)

    story
    |> Ecto.Changeset.change(qa_ready_commit: @merged, qa_ready_at: DateTime.utc_now())
    |> CodeMySpec.Repo.update!()

    {:ok, _} = passed_qa_attempt(scope, story_id: story.id)

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

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @merged)

    Promotion.promote(scope, story.number)
  end

  test "a merge that moves the gitlink fetches the pinned commit, checks it out, and restarts" do
    assert {:ok, %{merged: "story/x"}} = promote(%{})

    assert_received {:git, @sub, ["fetch", "--quiet", @agent <> "/.code_my_spec", "HEAD"]}
    assert_received {:git, @sub, ["checkout", "--quiet", @new_pin]}
    assert_receive :restarted, 2_000
  end

  test "a pinned commit that cannot be fetched refuses the promote, rolls back, and never restarts" do
    failing = %{
      {@sub, ["fetch", "--quiet", @agent <> "/.code_my_spec", "HEAD"]} =>
        {"fatal: upload-pack: not our ref #{@new_pin}", 128}
    }

    assert {:error, %{reason: reason}} = promote(failing)

    assert reason =~ @new_pin
    assert reason =~ @agent <> "/.code_my_spec"
    assert reason =~ "not our ref"
    assert_received {:git, @main, ["reset", "--keep", @base]}
    refute_received {:git, @sub, ["checkout" | _]}
    refute_receive :restarted, 200
  end

  # Harness session: undoing a commit somebody else made is worse than stale docs.
  test "a main that moved since the merge is not reset, and the refusal says so" do
    Process.put(:later_head, @moved)

    failing = %{
      {@sub, ["fetch", "--quiet", @agent <> "/.code_my_spec", "HEAD"]} =>
        {"fatal: upload-pack: not our ref #{@new_pin}", 128}
    }

    assert {:error, %{reason: reason}} = promote(failing)

    assert reason =~ "NOT rolled back"
    assert reason =~ @moved
    refute_received {:git, @main, ["reset" | _]}
    refute_receive :restarted, 200
  end

  test "a merge that leaves the gitlink alone runs no submodule command" do
    unchanged = %{{@main, ["ls-tree", @merged, "--", ".code_my_spec"]} => gitlink(@old_pin)}

    assert {:ok, %{merged: "story/x"}} = promote(unchanged)

    refute_received {:git, @sub, _}
    assert_receive :restarted, 2_000
  end

  # 8b27cc4c: metric_flow tracks `.code_my_spec` as ordinary files. Its tree SHA
  # moving is a merge like any other, not a pin to check out.
  test "a .code_my_spec tracked as a plain directory is merged, not synced as a submodule" do
    plain = %{
      {@main, ["ls-tree", @base, "--", ".code_my_spec"]} =>
        {"040000 tree #{@old_pin}\t.code_my_spec\n", 0},
      {@main, ["ls-tree", @merged, "--", ".code_my_spec"]} =>
        {"040000 tree #{@new_pin}\t.code_my_spec\n", 0},
      # What real git answers for a tree path, which is what read as a pin.
      {@main, ["rev-parse", "--verify", "--quiet", @base <> ":.code_my_spec"]} =>
        {@old_pin <> "\n", 0},
      {@main, ["rev-parse", "--verify", "--quiet", @merged <> ":.code_my_spec"]} =>
        {@new_pin <> "\n", 0}
    }

    assert {:ok, %{merged: "story/x"}} = promote(plain)

    refute_received {:git, @sub, _}
    refute_received {:git, @main, ["reset" | _]}
    assert_receive :restarted, 2_000
  end
end
