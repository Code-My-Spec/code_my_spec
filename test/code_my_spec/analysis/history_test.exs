defmodule CodeMySpec.Analysis.HistoryTest do
  use CodeMySpecTest.DataCase, async: false

  import Ecto.Query
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.History
  alias CodeMySpec.Analysis.History.Finding
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo

  @commit String.duplicate("a", 40)

  setup do
    %{scope: full_scope_fixture()}
  end

  defp run(scope, source, kind), do: run(scope, source, kind, DateTime.utc_now())

  defp run(scope, source, kind, finished_at) do
    %Run{}
    |> Run.changeset(%{
      source: source,
      kind: kind,
      status: :completed,
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      started_at: DateTime.add(finished_at, -1, :hour),
      finished_at: finished_at
    })
    |> Repo.insert!()
    |> Run.tree_changeset(%{
      start_commit: @commit,
      completed_commit: @commit,
      start_tree_dirty: false
    })
    |> Repo.update!()
  end

  defp failure(source, file, test_name) do
    %Problem{
      severity: :error,
      source_type: :test,
      source: source,
      file_path: file,
      line: 12,
      message: "assertion failed",
      category: "test_failure",
      metadata: %{"test" => test_name}
    }
  end

  test "a full run retains failures and infers a pass only for its own test source", %{
    scope: scope
  } do
    run = run(scope, "exunit", :full)
    :ok = History.record!(run, [failure("exunit", "test/a_test.exs", "test A")])

    assert [%Finding{file_path: "test/a_test.exs", test_name: "test A"}] =
             History.failures(scope, run)

    refute History.passed?(scope, @commit, "test/a_test.exs", "test A")
    assert History.passed?(scope, @commit, "test/b_test.exs", "test B")
    refute History.passed?(scope, @commit, "test/spex/b_spex.exs", "scenario B")
    assert run.working_copy_id == scope.active_working_copy_id
    assert run.kind == :full
    assert run.start_commit == @commit
  end

  test "a partial spex failure keeps its criterion without altering current problems", %{
    scope: scope
  } do
    run = run(scope, "spex", :partial)

    before_count =
      Repo.aggregate(from(p in Problem, where: p.project_id == ^scope.active_project_id), :count)

    file = "test/spex/1163_history/criterion_2401_failure_spex.exs"
    :ok = History.record!(run, [failure("spex", file, "scenario fails")])

    assert [%Finding{file_path: ^file, criterion: 2401, test_name: "scenario fails"}] =
             History.failures(scope, run)

    assert Repo.aggregate(
             from(p in Problem, where: p.project_id == ^scope.active_project_id),
             :count
           ) ==
             before_count

    refute History.passed?(scope, @commit, file, "scenario fails")
  end

  test "one prune deletes expired runs and findings but keeps newer and running runs", %{
    scope: scope
  } do
    old = run(scope, "exunit", :full, DateTime.add(DateTime.utc_now(), -31, :day))
    fresh = run(scope, "exunit", :full, DateTime.add(DateTime.utc_now(), -29, :day))
    :ok = History.record!(old, [failure("exunit", "test/old_test.exs", "old")])
    :ok = History.record!(fresh, [failure("exunit", "test/new_test.exs", "new")])

    assert {:ok, 1} = History.prune(scope)
    assert Repo.get(Run, old.id) == nil
    assert Repo.get(Finding, hd(History.failures(scope, fresh)).id)
    assert History.failures(scope, old) == []

    previous = Application.fetch_env(:code_my_spec, History)

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:code_my_spec, History, config)
        :error -> Application.delete_env(:code_my_spec, History)
      end
    end)
    Application.put_env(:code_my_spec, History, retention_days: 7)
    assert {:ok, 1} = History.prune(scope)
    assert Repo.get(Run, fresh.id) == nil
  end
end
