defmodule CodeMySpec.StoryReconcileTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.QaFixtures
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.StoryReconcile
  alias CodeMySpec.WorkingCopies

  @head String.duplicate("a", 40)
  @other String.duplicate("b", 40)

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{criteria: []})
    %{scope: scope, story: story}
  end

  defp spec!(scope, story, criterion, path) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      story_id: story.id,
      criterion_number: criterion.number,
      path: path,
      role: :bdd_spec,
      valid: true
    })

    path
  end

  defp failing!(scope, path),
    do: problem_fixture(scope, %{source: "spex", source_type: :test, file_path: path})

  defp plan(scope, head_paths, opts \\ []),
    do: StoryReconcile.plan(scope, [head: @head, head_paths: head_paths] ++ opts)

  defp latched?(scope, criterion),
    do: not is_nil(AcceptanceCriteria.get_criterion!(scope, criterion.id).latched_at)

  defp attempt!(story, status) do
    Repo.insert!(
      QaAttempt.changeset(%{
        story_id: story.id,
        status: status,
        scenarios: [%{name: "s", status: status, observation: "o"}],
        submitted_at: DateTime.utc_now()
      })
    )
  end

  describe "step 1: latch passing criteria" do
    test "latches a criterion whose spex passed on the clean run at HEAD, and only that one",
         %{scope: scope, story: story} do
      passing = criterion_fixture(scope, story)
      failing = criterion_fixture(scope, story)
      unrun = criterion_fixture(scope, story)
      uncommitted = criterion_fixture(scope, story)

      p1 = spec!(scope, story, passing, "test/spex/1/criterion_#{passing.number}_spex.exs")
      p2 = spec!(scope, story, failing, "test/spex/1/criterion_#{failing.number}_spex.exs")
      spec!(scope, story, uncommitted, "test/spex/1/criterion_#{uncommitted.number}_spex.exs")
      failing!(scope, p2)
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head)

      plan = plan(scope, [p1, p2])
      {:ok, items, counts} = plan.latch

      assert Enum.map(items, & &1.criterion.id) == [passing.id]
      assert %{failing: 1, no_spex: 1, not_at_head: 1} = counts

      assert :ok = StoryReconcile.carry_out(scope, plan)
      assert latched?(scope, passing)
      refute latched?(scope, failing)
      refute latched?(scope, unrun)
      refute latched?(scope, uncommitted)
    end

    test "never unlatches, and skips what is already latched", %{scope: scope, story: story} do
      criterion = criterion_fixture(scope, story)
      {:ok, criterion} = AcceptanceCriteria.latch_criterion(scope, criterion)
      path = spec!(scope, story, criterion, "test/spex/1/c_spex.exs")
      failing!(scope, path)
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head)

      plan = plan(scope, [path])
      assert {:ok, [], %{already: 1}} = plan.latch
      assert :ok = StoryReconcile.carry_out(scope, plan)
      assert latched?(scope, criterion)
    end

    test "refuses when no completed spex run answers for HEAD", %{scope: scope, story: story} do
      criterion = criterion_fixture(scope, story)
      path = spec!(scope, story, criterion, "test/spex/1/c_spex.exs")
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @other)

      assert {:refused, message, []} = plan(scope, [path]).latch
      assert message =~ "No completed spex run answers for HEAD #{@head}"
      assert message =~ "Run analysis"
    end

    test "refuses a run that started on a dirty tree", %{scope: scope, story: story} do
      criterion = criterion_fixture(scope, story)
      path = spec!(scope, story, criterion, "test/spex/1/c_spex.exs")
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head, start_tree_dirty: true)

      assert {:refused, message, []} = plan(scope, [path]).latch
      assert message =~ "dirty tree"
    end

    test "refuses when a failure is filed against no spec file", %{scope: scope, story: story} do
      criterion = criterion_fixture(scope, story)
      path = spec!(scope, story, criterion, "test/spex/1/c_spex.exs")
      failing!(scope, "unknown")
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head)

      assert {:refused, message, []} = plan(scope, [path]).latch
      assert message =~ "filed against no spec file"
    end
  end

  describe "step 2: ready-for-QA stamp" do
    test "stamps a story whose latest QA attempt passed with HEAD", %{scope: scope, story: story} do
      failed_story = story_fixture(scope, %{criteria: []})
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: story.id)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: failed_story.id)
      attempt!(failed_story, :fail)

      plan = plan(scope, [])
      assert {:ok, [item], %{already: 0}} = plan.qa_ready
      assert item.story.id == story.id
      assert item.after == @head

      assert :ok = StoryReconcile.carry_out(scope, plan)
      assert Stories.get_story!(scope, story.id).qa_ready_commit == @head
      assert Stories.get_story!(scope, failed_story.id).qa_ready_commit == nil
    end

    test "leaves an existing stamp alone", %{scope: scope, story: story} do
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: story.id)
      {:ok, _} = Stories.set_qa_ready(scope, story, @other)

      assert {:ok, [], %{already: 1}} = plan(scope, []).qa_ready
    end
  end

  describe "dry run" do
    test "planning writes nothing", %{scope: scope, story: story} do
      criterion = criterion_fixture(scope, story)
      path = spec!(scope, story, criterion, "test/spex/1/c_spex.exs")
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: story.id)

      plan = plan(scope, [path])
      assert {:ok, [_], _} = plan.latch
      assert {:ok, [_], _} = plan.qa_ready

      refute latched?(scope, criterion)
      assert Stories.get_story!(scope, story.id).qa_ready_commit == nil
    end
  end

  describe "step 3: un-park" do
    test "is skipped unless asked for", %{scope: scope} do
      assert plan(scope, []).unpark == :skipped
    end

    test "un-parks a fully latched, QA-passed story and its stamp survives", %{scope: scope} do
      parked = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion = criterion_fixture(scope, parked)
      path = spec!(scope, parked, criterion, "test/spex/2/c_spex.exs")
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: parked.id)

      plan = plan(scope, [path], unpark: true)
      assert {:ok, [candidate], _} = plan.unpark
      assert candidate.story.id == parked.id

      assert :ok = StoryReconcile.carry_out(scope, plan)
      parked = Stories.get_story!(scope, parked.id)
      assert parked.ready_for_dev
      assert parked.qa_ready_commit == @head
      assert latched?(scope, criterion)
    end

    test "re-stamps a released story with the stamp it had", %{scope: scope} do
      parked = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion = criterion_fixture(scope, parked)
      {:ok, _} = AcceptanceCriteria.latch_criterion(scope, criterion)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: parked.id)
      {:ok, parked} = Stories.set_qa_ready(scope, parked, @other)

      plan = plan(scope, [], unpark: true)
      assert {:ok, [_], _} = plan.unpark
      assert {:ok, [%{after: @other, source: :kept}], %{already: 0}} = plan.qa_ready

      assert :ok = StoryReconcile.carry_out(scope, plan)
      released = Stories.get_story!(scope, parked.id)
      assert released.ready_for_dev
      assert released.qa_ready_commit == @other
      assert DateTime.compare(released.qa_ready_at, parked.qa_ready_at) == :eq
    end

    test "a specs_ready story un-parked by --unpark keeps its latch and commit", %{scope: scope} do
      parked = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion = criterion_fixture(scope, parked)
      {:ok, _} = AcceptanceCriteria.latch_criterion(scope, criterion)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: parked.id)
      at = ~U[2026-10-01 12:00:00.000000Z]
      {:ok, _} = Stories.set_specs_ready(scope, parked, true, at: at, commit: @other)

      plan = plan(scope, [], unpark: true)
      assert {:ok, [_], _} = plan.unpark
      assert :ok = StoryReconcile.carry_out(scope, plan)

      released = Stories.get_story!(scope, parked.id)
      assert released.ready_for_dev
      assert released.specs_ready
      assert released.specs_ready_commit == @other
      assert DateTime.compare(released.specs_ready_at, at) == :eq
    end

    test "leaves a story parked when a criterion is unlatched or QA has not passed",
         %{scope: scope} do
      unlatched = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion_fixture(scope, unlatched)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: unlatched.id)

      unqa = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      {:ok, _} = AcceptanceCriteria.latch_criterion(scope, criterion_fixture(scope, unqa))

      assert {:ok, [], _} = plan(scope, [], unpark: true).unpark
    end

    test "a dry run with --unpark writes nothing", %{scope: scope} do
      parked = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion = criterion_fixture(scope, parked)
      path = spec!(scope, parked, criterion, "test/spex/2/c_spex.exs")
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: parked.id)

      plan = plan(scope, [path], unpark: true)
      assert {:ok, [_], _} = plan.unpark

      parked = Stories.get_story!(scope, parked.id)
      refute parked.ready_for_dev
      assert parked.qa_ready_commit == nil
      refute latched?(scope, criterion)
    end
  end

  describe "bind_checkout/2" do
    test "binds the working copy registered at the root", %{scope: scope} do
      {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
      root = Path.join(System.tmp_dir!(), "reconcile_#{System.unique_integer([:positive])}")
      WorkingCopies.report_root(copy, root)

      assert {:ok, %{active_working_copy_id: id}} =
               StoryReconcile.bind_checkout(%{scope | active_working_copy_id: nil}, root)

      assert id == copy.id
      assert {:error, message} = StoryReconcile.bind_checkout(scope, root <> "_elsewhere")
      assert message =~ "No working copy"
    end
  end
end
