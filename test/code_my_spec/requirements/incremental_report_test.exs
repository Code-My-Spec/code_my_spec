defmodule CodeMySpec.Requirements.IncrementalReportTest do
  @moduledoc """
  The report has to be able to tell an incremental pass from a full one, or it
  cannot carry the claim it exists to carry.

  Both directions are checked deliberately. A report that says "incremental"
  whatever happened is worth nothing, and the only way to know it is not doing
  that is to show it reporting a full rebuild as a full rebuild.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.{GraphWatcher, Node}

  setup do
    scope = full_scope_fixture()
    {:ok, _pid} = GraphWatcher.ensure_watching(scope)
    :ok = GraphWatcher.settle(scope)
    %{scope: scope}
  end

  # A pass stamps every row it wrote with one instant, so a pass is exactly a
  # distinct `checked_at`. Backdating some rows is how a test says "these were
  # written by an earlier pass" without waiting for one.
  defp backdate(scope, count, seconds_ago) do
    at =
      DateTime.utc_now()
      |> DateTime.add(-seconds_ago, :second)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)

    ids =
      from(n in Node,
        where: n.project_id == type(^scope.active_project_id, :binary_id),
        limit: ^count,
        select: n.id
      )
      |> Repo.all()

    Repo.update_all(from(n in Node, where: n.id in ^ids), set: [checked_at: at])
    length(ids)
  end

  test "a pass that touched a few rows reads as a few rows", %{scope: scope} do
    Requirements.recompute(scope)

    total = Repo.aggregate(from(n in Node), :count)
    assert total > 3, "need more rows than the pass under test touches"

    # Everything belongs to one old pass, then three rows move.
    backdate(scope, total, 600)
    moved = backdate(scope, 3, 0)

    report = Requirements.incremental_report(scope)
    newest = List.first(report.passes)

    assert newest.rows == moved,
           """
           The newest pass reported #{newest.rows} rows where #{moved} moved.

           A pass is a distinct `checked_at`, so this is the whole measurement
           — if it cannot count one pass it cannot say anything about whether
           the graph is incremental.

           passes: #{inspect(report.passes)}
           """

    assert newest.share < 0.5,
           "#{moved} of #{report.total_rows} rows should not read as most of the project"
  end

  test "a full rebuild reads as a full rebuild", %{scope: scope} do
    Requirements.recompute(scope)

    total = Repo.aggregate(from(n in Node), :count)
    backdate(scope, total, 0)

    report = Requirements.incremental_report(scope)
    newest = List.first(report.passes)

    assert newest.share == 1.0,
           """
           Every row was stamped by one pass and the report did not say so.

           This is the direction that matters most: a report which cannot show
           a full recompute as a full recompute would call any behaviour
           incremental, including the behaviour this whole change removed.

           newest: #{inspect(newest)}
           """
  end

  test "it reports without computing anything", %{scope: scope} do
    Requirements.recompute(scope)

    before_stamps =
      from(n in Node, select: n.checked_at) |> Repo.all() |> Enum.uniq() |> Enum.sort()

    Requirements.incremental_report(scope)
    Requirements.incremental_report(scope)

    after_stamps =
      from(n in Node, select: n.checked_at) |> Repo.all() |> Enum.uniq() |> Enum.sort()

    assert before_stamps == after_stamps,
           """
           Reading the report moved the rows it reports on.

           It exists to answer whether the graph recomputes incrementally, and
           a page that recomputes on being opened would be producing the
           freshness it claims to observe — which is the exact mistake this
           whole change removes from the read path.
           """
  end

  test "a vantage nothing has written is still listed, at zero", %{scope: scope} do
    Requirements.recompute(scope)

    report = Requirements.incremental_report(scope)

    assert Enum.any?(report.vantages, &(&1.vantage == nil)),
           """
           The unscoped vantage is missing from the report.

           It is the row-space every reader that is not an agent resolves to,
           and a watcher maintaining one checkout while leaving it frozen is a
           real failure that nothing surfaced at the time. Listing it at zero
           is how that becomes visible.

           vantages: #{inspect(report.vantages)}
           """
  end
end
