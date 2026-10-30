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

  test "a historical same-commit pass no longer confirms a flake", %{scope: scope} do
    commit = sha(1)
    completed_run(scope, commit, [@b])

    assert [a, b] = Flakes.classify_all(scope, commit, [@a, @b])
    assert a.classification == :no_flake_evidence
    assert a.evidence == []
    assert b.classification == :no_flake_evidence
  end

  test "distinct unrelated candidates meet the configured threshold", %{scope: scope} do
    runs =
      for n <- 1..3 do
        {:ok, copy} =
          WorkingCopies.issue(scope, nil, label: "candidate #{n}", device: device_fixture(scope))

        completed_run(%{scope | active_working_copy_id: copy.id}, sha(n + 3), [@a])
      end

    unrelated? = fn _run, _failure -> true end

    no_evidence =
      Flakes.classify(scope, sha(9), @a, unrelated_candidate?: unrelated?, suspect_threshold: 4)

    assert no_evidence.classification == :no_flake_evidence

    result = Flakes.classify(scope, sha(9), @a, unrelated_candidate?: unrelated?)
    assert result.classification == :suspected_flake
    assert Enum.sort(Enum.map(result.evidence, & &1.run_id)) == Enum.sort(Enum.map(runs, & &1.id))
  end

  defp completed_run(scope, commit, failures) do
    run = analysis_run_fixture(scope, %{kind: :full, status_override: :completed})

    run =
      RunsRepository.record_tree(run, %{
        start_commit: commit,
        completed_commit: commit,
        start_tree_dirty: false
      })

    History.record!(run, failures, [])
  end

  defp sha(n), do: n |> Integer.to_string(16) |> String.pad_leading(40, "0")
end
