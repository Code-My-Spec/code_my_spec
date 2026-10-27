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
             Flakes.classify(scope, @commit, [@failure])

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
end
