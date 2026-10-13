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

  defp plan(scope, opts \\ []), do: StoryReconcile.plan(scope, [head: @head] ++ opts)

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

  describe "step 2: ready-for-QA stamp" do
    test "stamps a story whose latest QA attempt passed with HEAD", %{scope: scope, story: story} do
      failed_story = story_fixture(scope, %{criteria: []})
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: story.id)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: failed_story.id)
      attempt!(failed_story, :fail)

      plan = plan(scope)
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

      assert {:ok, [], %{already: 1}} = plan(scope).qa_ready
    end
  end

  describe "dry run" do
    test "planning writes nothing", %{scope: scope, story: story} do
      criterion = criterion_fixture(scope, story)
      path = spec!(scope, story, criterion, "test/spex/1/c_spex.exs")
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: story.id)

      plan = plan(scope)
      assert {:ok, [_], _} = plan.qa_ready

      assert Stories.get_story!(scope, story.id).qa_ready_commit == nil
    end
  end

  describe "step 3: un-park" do
    test "is skipped unless asked for", %{scope: scope} do
      assert plan(scope).unpark == :skipped
    end

    test "un-parks a QA-passed story and its stamp survives", %{scope: scope} do
      parked = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion = criterion_fixture(scope, parked)
      path = spec!(scope, parked, criterion, "test/spex/2/c_spex.exs")
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: parked.id)

      plan = plan(scope, unpark: true)
      assert {:ok, [candidate], _} = plan.unpark
      assert candidate.story.id == parked.id

      assert :ok = StoryReconcile.carry_out(scope, plan)
      parked = Stories.get_story!(scope, parked.id)
      assert parked.ready_for_dev
      assert parked.qa_ready_commit == @head
    end

    test "re-stamps a released story with the stamp it had", %{scope: scope} do
      parked = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion = criterion_fixture(scope, parked)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: parked.id)
      {:ok, parked} = Stories.set_qa_ready(scope, parked, @other)

      plan = plan(scope, unpark: true)
      assert {:ok, [_], _} = plan.unpark
      assert {:ok, [%{after: @other, source: :kept}], %{already: 0}} = plan.qa_ready

      assert :ok = StoryReconcile.carry_out(scope, plan)
      released = Stories.get_story!(scope, parked.id)
      assert released.ready_for_dev
      assert released.qa_ready_commit == @other
      assert DateTime.compare(released.qa_ready_at, parked.qa_ready_at) == :eq
    end

    test "a specs_ready story un-parked by --unpark keeps its specs_ready and commit", %{
      scope: scope
    } do
      parked = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion = criterion_fixture(scope, parked)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: parked.id)
      at = ~U[2026-10-01 12:00:00.000000Z]
      {:ok, _} = Stories.set_specs_ready(scope, parked, true, at: at, commit: @other)

      plan = plan(scope, unpark: true)
      assert {:ok, [_], _} = plan.unpark
      assert :ok = StoryReconcile.carry_out(scope, plan)

      released = Stories.get_story!(scope, parked.id)
      assert released.ready_for_dev
      assert released.specs_ready
      assert released.specs_ready_commit == @other
      assert DateTime.compare(released.specs_ready_at, at) == :eq
    end

    test "leaves a story parked when QA has not passed", %{scope: scope} do
      unqa = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion_fixture(scope, unqa)

      assert {:ok, [], _} = plan(scope, unpark: true).unpark
    end

    test "a dry run with --unpark writes nothing", %{scope: scope} do
      parked = story_fixture(scope, %{criteria: [], ready_for_dev: false})
      criterion = criterion_fixture(scope, parked)
      path = spec!(scope, parked, criterion, "test/spex/2/c_spex.exs")
      fresh_analysis_runs_fixture(scope, ["spex"], commit: @head)
      {:ok, _} = QaFixtures.passed_qa_attempt(scope, story_id: parked.id)

      plan = plan(scope, unpark: true)
      assert {:ok, [_], _} = plan.unpark

      parked = Stories.get_story!(scope, parked.id)
      refute parked.ready_for_dev
      assert parked.qa_ready_commit == nil
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
