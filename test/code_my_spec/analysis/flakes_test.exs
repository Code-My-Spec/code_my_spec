defmodule CodeMySpec.Analysis.FlakesTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.{Flakes, History, RunsRepository}

  @commit String.duplicate("a", 40)
  @failure %{"file" => "test/a_test.exs", "name" => "test A"}

  test "classify reads a retained full run for the project and cites it" do
    scope = full_scope_fixture()
    run = analysis_run_fixture(scope)
    {:ok, run} = RunsRepository.finish_run(run, :completed, %{exit_status: 0})
    run = RunsRepository.record_tree(run, %{start_commit: @commit, completed_commit: @commit})
    History.record!(run, [], [])

    assert [%{classification: :confirmed_flake, evidence: %{run_id: run_id}}] =
             Flakes.classify_gate(scope, @commit, [@failure])

    assert run_id == run.id
  end

  test "a full same-commit pass confirms a flake and names its run" do
    history = [run("passing-run", @commit, [])]

    assert %{
             classification: :confirmed_flake,
             evidence: %{run_id: "passing-run", commit: @commit}
           } =
             Flakes.classify_one(@failure, @commit, history, [])
  end

  test "another commit, partial run, or wrong source does not confirm a flake" do
    history = [
      run("other-commit", String.duplicate("b", 40), []),
      %{run("partial", @commit, []) | partial: true},
      %{run("wrong-source", @commit, []) | source: "spex"}
    ]

    assert %{classification: :failure} = Flakes.classify_one(@failure, @commit, history, [])
  end

  test "three unrelated candidates make a failure suspect and identify them" do
    candidates = for id <- ~w(one two three), do: candidate(id, ["lib/other.ex"])

    assert %{classification: :suspected_flake, evidence: %{candidate_ids: ~w(one two three)}} =
             Flakes.classify_one(@failure, @commit, [], candidates)
  end

  test "a candidate touching the test or covered code is not suspect evidence" do
    candidates = [
      candidate("test-change", ["test/a_test.exs"]),
      candidate("covered-change", ["lib/covered.ex"]),
      candidate("unrelated", ["lib/other.ex"])
    ]

    assert %{classification: :failure, evidence: %{}} =
             Flakes.classify_one(@failure, @commit, [], candidates)
  end

  test "each gate failure receives its own classification" do
    other = %{"file" => "test/b_test.exs", "name" => "test B"}
    history = [run("passing-run", @commit, [other])]

    assert [
             %{failure: @failure, classification: :confirmed_flake},
             %{failure: ^other, classification: :failure}
           ] = Enum.map([@failure, other], &Flakes.classify_one(&1, @commit, history, []))
  end

  defp run(id, commit, failures) do
    %{
      run_id: id,
      commit: commit,
      source: "exunit",
      status: :completed,
      partial: false,
      failures: failures
    }
  end

  defp candidate(id, changed_files) do
    %{
      id: id,
      failures: [@failure],
      changed_files: changed_files,
      covered_files: ["lib/covered.ex"]
    }
  end

  import CodeMySpec.DevicesFixtures

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
