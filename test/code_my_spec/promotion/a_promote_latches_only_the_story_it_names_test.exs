defmodule CodeMySpec.Promotion.APromoteLatchesOnlyTheStoryItNamesTest do
  @moduledoc """
  e1174640: `promote` takes the story being promoted. That story alone is
  latched (`specs_ready`) and stamped (`promoted_version`), and only when all
  of its spex pass on the promoting copy's certifying run. No other story is
  touched — the project-wide stamp is gone.

  Git is scripted through the in-memory environment's per-env shell; nothing
  shells out.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Environments
  alias CodeMySpec.Files
  alias CodeMySpec.Promotion
  alias CodeMySpec.Stories
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.WorkingCopies

  @main "/promote-story/main"
  @agent "/promote-story/agent"
  @head "1111111111111111111111111111111111111111"
  @agent_head "2222222222222222222222222222222222222222"

  # A no-op fast-forward: main's HEAD does not move, so nothing is minted and
  # the story is stamped with the version main already carries (47bb8f1cc).
  defp script do
    test = self()

    fn "git", args, opts ->
      cd = Keyword.fetch!(opts, :cd)
      send(test, {:git, cd, args})
      answer(cd, args)
    end
  end

  defp answer(@agent, ["merge-base", "--is-ancestor", @head, "HEAD"]), do: {"", 0}
  defp answer(@agent, ["status" | _]), do: {"", 0}
  defp answer(@agent, ["rev-parse", "--abbrev-ref", "HEAD"]), do: {"story/x\n", 0}
  defp answer(@agent, ["rev-parse", "HEAD"]), do: {@agent_head <> "\n", 0}
  defp answer(@agent, ["ls-files" | _]), do: {"", 0}
  defp answer(@main, ["rev-parse", "HEAD"]), do: {@head <> "\n", 0}
  defp answer(@main, ["diff" | _]), do: {"", 0}
  defp answer(@main, ["merge", "--ff-only", @agent_head]), do: {"Already up to date.\n", 0}

  defp answer(@main, ["show", "HEAD:mix.exs"]),
    do: {~s|def project, do: [app: :x, version: "0.3.3"]\n|, 0}

  defp answer(cd, args), do: {"unscripted: git #{Enum.join(args, " ")} in #{cd}", 1}

  defp a_running_app(working_copy_id) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "test-harness", @main)
      send(test, :registered)

      receive do
        {:"$gen_call", from, {:restart_app, _request}} ->
          GenServer.reply(from, {:ok, %{status: "serving", url: "http://x", commit: @head}})
      end
    end)

    assert_receive :registered, 2_000
  end

  defp a_project do
    scope = full_scope_fixture()

    {:ok, running} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, running} = WorkingCopies.report_root(running, @main)
    a_running_app(running.id)

    {:ok, agent} = WorkingCopies.issue(scope, nil, label: "agent", device: device_fixture(scope))
    {:ok, agent} = WorkingCopies.report_root(agent, @agent)

    {:ok, env} = InMemoryEnvironment.create(shell: script())
    :ok = Environments.register({:working_copy, running.id}, env)
    :ok = Environments.register({:working_copy, agent.id}, env)

    %{
      scope: put_fixture_environment(%{scope | active_working_copy_id: agent.id}, env),
      running: running
    }
  end

  # A spec file linked to the story on the promoting copy, red or green there.
  defp with_spex(scope, story, red?) do
    path = "test/spex/#{story.number}_feature/criterion_1_spex.exs"

    {_n, _} =
      Files.upsert_files(scope, [
        %{path: path, role: :bdd_spec, story_id: story.id, valid: true, mtime: DateTime.utc_now()}
      ])

    red(red?, scope, path)
    path
  end

  defp red(false, _scope, _path), do: :ok

  defp red(true, scope, path) do
    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: path,
      message: "expected the war to be declared",
      severity: :error,
      category: "spex"
    })
  end

  # Each copy's analyzers ran clean at its own HEAD.
  defp certified(%{scope: scope, running: running}) do
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @agent_head)

    AnalysisFixtures.fresh_analysis_runs_fixture(
      %{scope | active_working_copy_id: running.id},
      Run.sources(),
      commit: @head
    )
  end

  # Work that is not a story's — a fix from an issue — still has to reach main.
  test "a promote with no story merges and latches or stamps nothing" do
    %{scope: scope} = project = a_project()

    green = story_fixture(scope, %{title: "Green, not named"})
    with_spex(scope, green, false)

    certified(project)

    assert {:ok, %{merged: "story/x"} = result} = Promotion.promote(scope, nil)
    refute Map.has_key?(result, :story)

    untouched = Stories.get_story!(scope, green.id)
    assert untouched.specs_ready == false
    assert untouched.promoted_version == nil
  end

  test "latches and stamps only the named story" do
    %{scope: scope} = project = a_project()

    named = story_fixture(scope, %{title: "Named"})
    with_spex(scope, named, false)

    latched_elsewhere = story_fixture(scope, %{title: "Already latched", specs_ready: true})
    with_spex(scope, latched_elsewhere, false)

    unlatched = story_fixture(scope, %{title: "Unlatched and green"})
    with_spex(scope, unlatched, false)

    certified(project)

    assert {:ok, %{merged: "story/x", story: %{number: number, version: "0.3.3"}}} =
             Promotion.promote(scope, named.number)

    assert number == named.number

    named = Stories.get_story!(scope, named.id)
    assert named.specs_ready == true
    assert named.promoted_version == "0.3.3"
    assert named.specs_ready_commit == @head
    assert %DateTime{} = named.specs_ready_at

    assert Stories.get_story!(scope, latched_elsewhere.id).promoted_version == nil,
           "a specs-ready story the promote did not name must not be stamped"

    untouched = Stories.get_story!(scope, unlatched.id)
    assert untouched.specs_ready == false
    assert untouched.promoted_version == nil
  end

  test "refuses when the named story's spex are red, and names them" do
    %{scope: scope} = project = a_project()

    story = story_fixture(scope, %{title: "Red"})
    red = with_spex(scope, story, true)
    certified(project)

    # Refused at the gate: every red spex blocks there (John, 2026-10-05).
    assert {:error, %{reason: reason}} = Promotion.promote(scope, story.number)
    assert reason =~ red
    refute_received {:git, @main, ["merge" | _]}

    story = Stories.get_story!(scope, story.id)
    assert story.specs_ready == false
    assert story.promoted_version == nil
  end

  test "refuses a story with no linked spex rather than latching on nothing" do
    %{scope: scope} = project = a_project()

    story = story_fixture(scope, %{title: "No spex"})
    certified(project)

    assert {:error, %{reason: reason}} = Promotion.promote(scope, story.number)
    assert reason =~ "no spex linked"
    refute_received {:git, @main, ["merge" | _]}
  end

  # Promoting from main itself: the same rule as a merge, minus the merge.
  describe "from the running copy" do
    defp on_main(%{scope: scope, running: running} = project),
      do: %{project | scope: %{scope | active_working_copy_id: running.id}}

    test "latches the story at main's HEAD and stamps main's current version" do
      %{scope: scope} = project = on_main(a_project())

      story = story_fixture(scope, %{title: "Worked on main"})
      with_spex(scope, story, false)
      other = story_fixture(scope, %{title: "Also green on main"})
      with_spex(scope, other, false)
      certified(project)

      assert {:ok, %{restarted: @main, story: %{number: number, version: "0.3.3"}}} =
               Promotion.promote(scope, story.number)

      assert number == story.number
      refute_received {:git, @main, ["merge" | _]}

      story = Stories.get_story!(scope, story.id)
      assert story.specs_ready == true
      assert story.promoted_version == "0.3.3"
      assert story.specs_ready_commit == @head

      other = Stories.get_story!(scope, other.id)
      assert other.specs_ready == false
      assert other.promoted_version == nil
    end

    test "refuses when the story's spex are red on main, and names them" do
      %{scope: scope} = project = on_main(a_project())

      story = story_fixture(scope, %{title: "Red on main"})
      red = with_spex(scope, story, true)
      certified(project)

      assert {:error, %{failing_spex: [^red]}} = Promotion.promote(scope, story.number)

      story = Stories.get_story!(scope, story.id)
      assert story.specs_ready == false
      assert story.promoted_version == nil
    end
  end
end
