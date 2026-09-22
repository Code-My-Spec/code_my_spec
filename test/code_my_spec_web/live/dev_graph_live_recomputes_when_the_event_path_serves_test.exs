defmodule CodeMySpecWeb.DevGraphLiveRecomputesWhenTheEventPathServesTest do
  @moduledoc """
  The stale panel's instrument follows the writer.

  The fingerprint diff judges rows the batched pass stamped. The event path
  stamps nothing — a handler settles a row from the observation — so under it
  every row the pass wrote before the flip reads as "moved past" the moment
  any input moves, whether or not the verdict did. Read on dev the first time
  after the flip: 447 of 1,134 components, every one agreeing with the pass.
  So when the event path serves, the panel recomputes every entity from its
  inputs and compares that with what is served.

  The harness panel is the same story one door over. It asked the server's
  own filesystem watcher, which nothing starts any more, and read every root
  as unwatched while every checkout was announcing fine.
  """
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Requirements.ShadowProjector

  setup %{conn: conn} do
    previous = %{
      projection: Application.get_env(:code_my_spec, :graph_shadow_projection, false),
      source: Application.get_env(:code_my_spec, :graph_event_is_source, false)
    }

    Application.put_env(:code_my_spec, :graph_shadow_projection, true)
    Application.put_env(:code_my_spec, :graph_event_is_source, true)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :graph_shadow_projection, previous.projection)
      Application.put_env(:code_my_spec, :graph_event_is_source, previous.source)
    end)

    scope = full_scope_fixture()
    {:ok, _pid} = GraphWatcher.ensure_watching(scope)
    :ok = GraphWatcher.settle(scope)
    :ok = ShadowProjector.settle(scope.active_project_id, [nil, scope.active_working_copy_id])
    Requirements.recompute(scope)
    Requirements.recompute(%{scope | active_working_copy_id: nil})

    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  test "the stale panel recomputes from the domain rather than reading the pass's fingerprints",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/dev/graph")

    assert html =~ ~s(data-test="recomputed"),
           "the event path serves and the page still judges it by the pass's fingerprints"

    assert html =~ "agree with the rows being served",
           """
           The recompute panel rendered, but not as agreeing on a freshly seeded
           project. Either a recompute from the domain really differs from the
           seed here — which the exactness tests would also be saying — or the
           panel misreads the report.
           """

    refute html =~ "inputs have moved past",
           "the fingerprint verdict must not be shown beside the oracle"
  end

  test "the harness panel reports whether a harness has joined, not a watcher nothing starts", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/dev/graph")

    refute html =~ "NOT watched"
    assert html =~ "NOT joined", "no harness joins in a unit test, and the panel should say so"
  end
end
