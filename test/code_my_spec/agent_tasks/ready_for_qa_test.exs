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

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.AgentTasks.ReadyForQa
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Stories
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.WorkingCopies

  @copy "/ready-for-qa/copy"
  @head "5555555555555555555555555555555555555555"

  defp script(status) do
    test = self()

    fn "git", args, opts ->
      send(test, {:git, Keyword.fetch!(opts, :cd), args})
      answer(status, args)
    end
  end

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

  defp a_copy(status \\ "") do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "copy", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, @copy)
    a_harness(copy.id)
    {:ok, env} = InMemoryEnvironment.create(shell: script(status))
    scope = %{scope | active_working_copy_id: copy.id, environment: env}
    %{scope: scope, story: story_fixture(scope)}
  end

  defp task(story), do: %{story_id: story.id}

  # One spec file linked to the story — a story with none has nothing that says
  # its spex pass, and certification refuses it.
  defp spec(scope, story) do
    path = "test/spex/#{story.id}_a_feature/criterion_1_spex.exs"

    CodeMySpec.Files.upsert_files(scope, [
      %{path: path, role: :bdd_spec, story_id: story.id, valid: true, mtime: DateTime.utc_now()}
    ])

    path
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

  # Story 983, criterion 1896: a never-latched criterion's red spex is
  # tolerated on a story's first certifying run, so this now needs a
  # criterion already latched before a red spex refuses again.
  test "the story's own red spex refuse it, once a criterion is already latched" do
    %{scope: scope, story: story} = a_copy()
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @head)
    path = spec(scope, story)

    [criterion | _] = AcceptanceCriteria.list_all_story_criteria(scope, story.id)
    {:ok, _} = AcceptanceCriteria.latch_criterion(scope, criterion)

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

  test "an already certified story's task says there is nothing to do" do
    %{scope: scope, story: story} = a_copy()
    {:ok, _} = Stories.set_qa_ready(scope, story, @head)

    assert {:ok, prompt} = ReadyForQa.command(scope, task(story))
    assert prompt =~ "already certified ready for QA at #{@head}"
    assert prompt =~ "evaluate_task"
  end

  test "the stamp clears with the specs latch" do
    %{scope: scope, story: story} = a_copy()
    {:ok, story} = Stories.set_qa_ready(scope, story, @head)

    {:ok, _} = Stories.set_specs_ready(scope, story, false)

    assert stamp(scope, story) == nil
  end
end
