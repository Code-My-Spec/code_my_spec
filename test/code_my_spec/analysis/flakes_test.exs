defmodule CodeMySpec.Analysis.FlakesTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.{Flakes, History, RunsRepository}
  alias CodeMySpec.WorkingCopies

  @test_file "test/war_test.exs"
  @a %{file: @test_file, name: "test A"}
  @b %{file: @test_file, name: "test B"}

  setup do
    %{scope: full_scope_fixture()}
  end

  test "a full same-commit pass confirms only the test it passed", %{scope: scope} do
    commit = sha(1)
    passing = completed_run(scope, commit, [@b])
    completed_run(scope, sha(2), [])
    completed_run(scope, commit, [@a], kind: :partial)

    assert [a, b] = Flakes.classify_all(scope, commit, [@a, @b])
    assert a.classification == :confirmed_flake
    assert Enum.map(a.evidence, & &1.run_id) == [passing.id]
    assert b.classification == :no_flake_evidence
    assert b.evidence == []
  end

  # An agent's copy runs its uncommitted work at the same commit; that run
  # passing a test says nothing about the committed code.
  test "a pass at the same commit on a dirty tree does not confirm a flake", %{scope: scope} do
    commit = sha(5)
    completed_run(scope, commit, [], dirty: true)

    assert Flakes.classify(scope, commit, @a).classification == :no_flake_evidence
  end

  test "a failed run or a missing snapshot cannot establish a pass", %{scope: scope} do
    commit = sha(3)
    run = analysis_run_fixture(scope, %{status_override: :failed})
    run = RunsRepository.record_tree(run, %{start_commit: commit, completed_commit: commit})
    History.record!(run, [], [])
    run = analysis_run_fixture(scope, %{status_override: :completed})
    RunsRepository.record_tree(run, %{start_commit: commit, completed_commit: commit})

    assert Flakes.classify(scope, commit, @a).classification == :no_flake_evidence
  end

  test "distinct unrelated candidates meet the configured threshold", %{scope: scope} do
    runs =
      for n <- 1..3 do
        {:ok, copy} =
          WorkingCopies.issue(scope, nil, label: "candidate #{n}", device: device_fixture(scope))

        completed_run(%{scope | active_working_copy_id: copy.id}, sha(n + 3), [@a])
      end

    related? = fn _run, _failure -> true end

    no_evidence =
      Flakes.classify(scope, sha(9), @a, unrelated_candidate?: related?, suspect_threshold: 4)

    assert no_evidence.classification == :no_flake_evidence

    result = Flakes.classify(scope, sha(9), @a, unrelated_candidate?: related?)
    assert result.classification == :suspected_flake
    assert Enum.sort(Enum.map(result.evidence, & &1.run_id)) == Enum.sort(Enum.map(runs, & &1.id))
  end

  defp completed_run(scope, commit, failures, opts \\ []) do
    kind = Keyword.get(opts, :kind, :full)
    dirty? = Keyword.get(opts, :dirty, false)
    run = analysis_run_fixture(scope, %{kind: kind, status_override: :completed})

    run =
      RunsRepository.record_tree(run, %{
        start_commit: commit,
        completed_commit: commit,
        start_tree_dirty: dirty?
      })

    History.record!(run, failures, [])
  end

  defp sha(n), do: n |> Integer.to_string(16) |> String.pad_leading(40, "0")
end
