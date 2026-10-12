defmodule CodeMySpec.AgentTasks.ReadyForQaTest do
  @moduledoc """
  The gate before QA works like promotion (John, 2026-10-02): completing
  `ready_for_qa` certifies the copy — a clean tree, every analyzer clean at
  HEAD's exact commit, the story's own spex green — and stamps that commit.
  Nothing about main is asked, and nothing merges.

  Git is scripted through the in-memory environment's shell; the copy's harness
  is a process that records the runs dispatched to it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.ReadyForQa
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Environments
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.WorkingCopies

  @copy "/ready-for-qa/copy"
  @head "5555555555555555555555555555555555555555"

  defp script(status, changed) do
    test = self()

    fn "git", args, opts ->
      send(test, {:git, Keyword.fetch!(opts, :cd), args})
      answer(status, changed, args)
    end
  end

  defp answer(_status, changed, ["diff", "--name-only", _range]),
    do: {Enum.join(changed, "\n"), 0}

  defp answer(status, _changed, args), do: answer(status, args)

  defp answer(:not_a_repository, ["status" | _]),
    do: {"fatal: not a git repository (or any of the parent directories): .git\n", 128}

  defp answer(status, ["status" | _]), do: {status, 0}
  defp answer(_status, ["rev-parse", "--abbrev-ref", "HEAD"]), do: {"story/x\n", 0}
  defp answer(_status, ["rev-parse", "HEAD"]), do: {@head <> "\n", 0}
  defp answer(_status, ["ls-files" | _]), do: {"", 0}
  defp answer(_status, args), do: {"unscripted: git #{Enum.join(args, " ")}", 1}

  defp a_harness(working_copy_id) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "copy-harness", @copy)
      send(test, :registered)
      forward(test)
    end)

    assert_receive :registered, 2_000
  end

  defp forward(test) do
    receive do
      {:run_analysis, runs} -> send(test, {:dispatched, runs})
      _other -> :ok
    end

    forward(test)
  end

  defp a_copy(status \\ "", changed \\ []) do
    scope = working_copy_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "copy", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, @copy)
    a_harness(copy.id)
    {:ok, env} = InMemoryEnvironment.create(shell: script(status, changed))
    scope = put_fixture_environment(%{scope | active_working_copy_id: copy.id}, env)
    :ok = Environments.register({:working_copy, copy.id}, env)
    %{scope: scope, story: story_fixture(scope)}
  end

  defp task(story), do: %{story_id: story.id}

  # One spec file linked to the story — a story with none has nothing that says
  # its spex pass, and certification refuses it.
  # A spex file per live criterion, each naming its criterion as a synced spex
  # does (`Files.SpecBinding`). Answers the first one's path.
  defp spec(scope, story) do
    rows =
      for criterion <- AcceptanceCriteria.list_story_criteria(scope, story.id) do
        %{
          path: "test/spex/#{story.number}_a_feature/criterion_#{criterion.number}_spex.exs",
          role: :bdd_spec,
          story_id: story.id,
          criterion_number: criterion.number,
          valid: true,
          mtime: DateTime.utc_now()
        }
      end

    CodeMySpec.Files.upsert_files(scope, rows)
    hd(rows).path
  end

  defp dispatched_sources do
    receive do
      {:dispatched, runs} -> Enum.map(runs, & &1["source"]) ++ dispatched_sources()
    after
      100 -> []
    end
  end

  defp stamp(scope, story), do: Stories.get_story(scope, story.id).qa_ready_commit

  # bab9a2a5: the offer said "use when ... its implementation is ready to be
  # tested", so a coder on a story with no implementation cancelled it.
  test "the offer says this is where the story's specs are made to pass" do
    description = ReadyForQa.dispatch(nil)

    assert description =~ "Make this story's specs pass"
    assert description =~ "implement"
    refute description =~ "implementation is ready"
  end

  test "a dirty tree is refused, and nothing is stamped" do
    %{scope: scope, story: story} = a_copy(" M lib/war.ex\n")

    assert {:ok, :invalid, feedback} = ReadyForQa.evaluate(scope, task(story), nil)
    assert feedback =~ "lib/war.ex"
    assert dispatched_sources() == []
    assert stamp(scope, story) == nil
  end

  test "a checkout that is not a git repository is refused, and told not to make one" do
    %{scope: scope, story: story} = a_copy(:not_a_repository)

    assert {:ok, :invalid, feedback} = ReadyForQa.evaluate(scope, task(story), nil)
    assert feedback =~ "not a git repository"
    assert feedback =~ "Do not create one"
    assert dispatched_sources() == []
  end

  test "with no run at HEAD, the gate starts every analyzer there and stays open" do
    %{scope: scope, story: story} = a_copy()

    assert {:ok, :pending, text} = ReadyForQa.evaluate(scope, task(story), nil)
    assert text =~ @head
    assert Enum.sort(dispatched_sources()) == Enum.sort(Run.sources())
    assert stamp(scope, story) == nil
  end

  test "clean runs at HEAD stamp that commit, without asking about main" do
    %{scope: scope, story: story} = a_copy()
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @head)
    spec(scope, story)

    assert {:ok, :valid, message} = ReadyForQa.evaluate(scope, task(story), nil)
    assert message =~ @head
    assert stamp(scope, story) == @head
    refute_received {:git, _cd, ["merge-base" | _]}
    assert dispatched_sources() == [], "a certified commit's runs are reused, not restarted"
  end

  test "the story's own red spex refuse it" do
    %{scope: scope, story: story} = a_copy()
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @head)
    path = spec(scope, story)

    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: path,
      message: "no match of right hand side value: []",
      severity: :error,
      category: "spex"
    })

    assert {:ok, :invalid, feedback} = ReadyForQa.evaluate(scope, task(story), nil)
    assert feedback =~ "spex"
    assert stamp(scope, story) == nil
  end

  test "evaluate/2 reads the stamp and starts nothing" do
    %{scope: scope, story: story} = a_copy()

    assert {:ok, :invalid, _} = ReadyForQa.evaluate(scope, task(story))
    assert dispatched_sources() == []

    {:ok, _} = Stories.set_qa_ready(scope, story, @head)
    assert {:ok, :valid, _} = ReadyForQa.evaluate(scope, task(story))
  end

  test "an already certified story's task says completing it checks HEAD" do
    %{scope: scope, story: story} = a_copy()
    {:ok, _} = Stories.set_qa_ready(scope, story, @head)

    assert {:ok, prompt} = ReadyForQa.command(scope, task(story))
    assert prompt =~ "certified ready for QA at #{@head}"
    assert prompt =~ "re-certifies"
    assert prompt =~ "evaluate_task"
  end

  test "the stamp clears with the specs latch" do
    %{scope: scope, story: story} = a_copy()
    {:ok, story} = Stories.set_qa_ready(scope, story, @head)

    {:ok, _} = Stories.set_specs_ready(scope, story, false)

    assert stamp(scope, story) == nil
  end

  @earlier "4444444444444444444444444444444444444444"

  defp certified_earlier(scope, story) do
    at = DateTime.add(DateTime.utc_now(), -3600)
    {:ok, story} = Stories.set_qa_ready(scope, story, @earlier, at)
    story
  end

  # Certified means at a commit: a stamp the branch has moved past is not read
  # back as a certification of what is there now.
  test "a stamp HEAD has moved past is re-certified at HEAD" do
    %{scope: scope, story: story} = a_copy("", ["test/war_test.exs"])
    certified_earlier(scope, story)
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @head)
    spec(scope, story)

    assert {:ok, :valid, message} = ReadyForQa.evaluate(scope, task(story), nil)
    assert message =~ @head
    assert stamp(scope, story) == @head
  end

  test "QA the story already has carries across a change QA does not exercise" do
    %{scope: scope, story: story} = a_copy("", ["test/war_test.exs", ".code_my_spec"])
    certified_earlier(scope, story)
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @head)
    spec(scope, story)

    assert {:ok, :valid, _} = ReadyForQa.evaluate(scope, task(story), nil)

    assert Stories.get_story(scope, story.id).qa_reviewed_commit == @earlier,
           "a test-only commit after QA made the pass stale, so it would cost another QA pass"
  end

  test "a product change after QA needs QA again" do
    %{scope: scope, story: story} = a_copy("", ["test/war_test.exs", "lib/war.ex"])
    certified_earlier(scope, story)
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @head)
    spec(scope, story)

    assert {:ok, :valid, _} = ReadyForQa.evaluate(scope, task(story), nil)
    assert Stories.get_story(scope, story.id).qa_reviewed_commit == @head
  end
end
