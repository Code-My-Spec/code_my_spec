defmodule CodeMySpecWeb.DevGraphLiveTest do
  @moduledoc """
  The page has to show a pass as the size it was, and it has to do it without
  computing one.

  Both halves are the point. A dashboard that renders is not evidence; a
  dashboard that renders the same reassuring thing whatever the graph did is
  worse than none, because it is quoted.
  """

  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.{GraphWatcher, Node}

  setup %{conn: conn} do
    scope = full_scope_fixture()
    {:ok, _pid} = GraphWatcher.ensure_watching(scope)
    :ok = GraphWatcher.settle(scope)
    Requirements.recompute(scope)

    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  defp stamp(scope, count, seconds_ago) do
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

  test "a small pass renders as a small pass", %{conn: conn, scope: scope} do
    total = Repo.aggregate(from(n in Node), :count)
    stamp(scope, total, 600)
    moved = stamp(scope, 2, 0)

    {:ok, _view, html} = live(conn, ~p"/dev/graph")

    assert html =~ "Incremental sync"

    assert html =~ ~r/<td[^>]*>\s*#{moved}\s*<\/td>/,
           """
           The newest pass moved #{moved} rows and the page does not say so.

           The size of a pass is the whole claim this page makes. If it cannot
           show it, it is decoration.
           """
  end

  test "it says so when nothing is watching the project", %{conn: conn, scope: scope} do
    :ok = CodeMySpecSpex.Fixtures.stop_watching(scope)

    {:ok, _view, html} = live(conn, ~p"/dev/graph")

    assert html =~ "Nothing is watching this project",
           """
           A project with no watcher rendered as an ordinary one.

           `settle/1` answers `:ok` when nothing is watching, so a dead watcher
           looks exactly like a quiet project everywhere else. This page is the
           one place that distinction is visible, and it is the difference
           between "nothing has happened" and "nothing can happen".
           """
  end

  test "the stale panel names an entity a silent writer moved", %{conn: conn, scope: scope} do
    # Two, so "stale" can be a subset. With a single entity every stale set is
    # also the whole set, and the report answers `{:all, why}` — a true answer
    # that names nothing, and not the one this page is for.
    story = CodeMySpec.StoriesFixtures.story_fixture(scope, %{ready_for_dev: true})
    _other = CodeMySpec.StoriesFixtures.story_fixture(scope, %{ready_for_dev: true})
    :ok = GraphWatcher.settle(scope)
    Requirements.recompute(scope)

    {:ok, view, html} = live(conn, ~p"/dev/graph")

    assert html =~ "Every entity&#39;s inputs agree" or html =~ "Every entity's inputs agree",
           "the premise did not hold: something was already stale before the write"

    # A write that reaches the database and announces nothing — the defect this
    # page exists to find. `updated_at` is bumped because `Freshness.row_key/1`
    # is `{id, updated_at}`, which is what a real writer moves.
    Repo.update_all(
      from(s in "stories", where: s.id == ^story.id),
      set: [
        description: "changed with nothing announcing it",
        updated_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_naive()
      ]
    )

    html = view |> element("button[phx-click='recheck']") |> render_click()

    assert html =~ "story:#{story.id}",
           """
           A silent write moved a story's inputs and the page did not name it.

           This is the page's reason to exist. A stale set that does not empty
           after a pass is how a writer that announced nothing gets found, and
           it has to say which entity or there is nothing to trace back.

           #{html}
           """
  end

  test "opening the page does not recompute the graph", %{conn: conn, scope: _scope} do
    before_stamps =
      from(n in Node, select: n.checked_at) |> Repo.all() |> Enum.uniq() |> Enum.sort()

    {:ok, _view, _html} = live(conn, ~p"/dev/graph")

    after_stamps =
      from(n in Node, select: n.checked_at) |> Repo.all() |> Enum.uniq() |> Enum.sort()

    assert before_stamps == after_stamps,
           """
           Opening the page moved the rows it reports on.

           It exists to answer whether the graph recomputes incrementally. A
           page that recomputes on being opened manufactures the freshness it
           claims to observe, which is the behaviour this whole change removed
           from the read path.
           """
  end
end
