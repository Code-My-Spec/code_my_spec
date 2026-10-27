defmodule CodeMySpec.Analysis.HistoryTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.{History, Run, RunsRepository}
  alias CodeMySpec.Repo

  setup do
    previous = Application.get_env(:code_my_spec, :analysis_retention_days)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:code_my_spec, :analysis_retention_days)
      else
        Application.put_env(:code_my_spec, :analysis_retention_days, previous)
      end
    end)

    %{scope: full_scope_fixture()}
  end

  test "retains findings with run metadata and infers an unlisted test passed", %{scope: scope} do
    commit = String.duplicate("a", 40)
    run = finished_run(scope)
    run = RunsRepository.record_tree(run, %{start_commit: commit, completed_commit: commit})
    failure = %{"file" => "test/a_test.exs", "name" => "test A", "message" => "failed"}
    problem = %{severity: :error, file_path: "test/a_test.exs", message: "failed"}
    History.record!(run, [failure], [problem])

    assert [
             %{
               run_id: id,
               commit: ^commit,
               source: "exunit",
               partial: false,
               working_copy_id: working_copy_id,
               failures: [stored_failure],
               problems: [stored_problem]
             }
           ] = History.list(scope)

    assert id == run.id
    assert working_copy_id == run.working_copy_id
    assert stored_failure == failure
    assert stored_problem["severity"] == "error"
    refute History.test_passed?(scope, commit, "test/a_test.exs", "test A")
    assert History.test_passed?(scope, commit, "test/b_test.exs", "test B")
  end

  test "prunes a run and its findings by age, not by count", %{scope: scope} do
    now = DateTime.utc_now()
    old = finished_run(scope) |> aged(31, now)
    recent = finished_run(scope) |> aged(29, now)
    History.record!(old, [%{"name" => "old"}], [%{message: "old"}])
    History.record!(recent, [%{"name" => "recent"}], [%{message: "recent"}])

    assert {:ok, 1} = History.prune(scope, now)
    assert Repo.get(Run, old.id) == nil
    assert [%{run_id: id, failures: [%{"name" => "recent"}]}] = History.list(scope)
    assert id == recent.id

    Application.put_env(:code_my_spec, :analysis_retention_days, 7)
    assert {:ok, 1} = History.prune(scope, now)
    assert History.list(scope) == []
  end

  test "keeps more than twenty recent runs", %{scope: scope} do
    for _ <- 1..25 do
      finished_run(scope)
    end

    assert length(History.list(scope, source: "exunit")) == 25
    assert {:ok, 0} = RunsRepository.prune(scope, "exunit")
    assert length(History.list(scope, source: "exunit")) == 25
  end

  test "a partial snapshot leaves current problems untouched", %{scope: scope} do
    run = finished_run(scope, %{kind: :partial})
    History.record!(run, [%{"name" => "targeted test"}], [%{message: "targeted"}])

    assert [%{partial: true, failures: [%{"name" => "targeted test"}]}] = History.list(scope)
  end

  defp finished_run(scope, attrs \\ %{}) do
    run = analysis_run_fixture(scope, attrs)
    {:ok, run} = RunsRepository.finish_run(run, :completed, %{exit_status: 0})
    run
  end

  defp aged(run, days, now) do
    run
    |> Ecto.Changeset.change(finished_at: DateTime.add(now, -days, :day))
    |> Repo.update!()
  end
end
