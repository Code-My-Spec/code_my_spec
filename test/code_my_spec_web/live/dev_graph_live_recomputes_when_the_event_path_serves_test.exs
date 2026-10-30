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
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Requirements.IncrementalGraph

  setup %{conn: conn} do
    scope = full_scope_fixture()
    {:ok, _pid} = GraphWatcher.ensure_watching(scope)
    :ok = GraphWatcher.settle(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id, [nil, scope.active_working_copy_id])
    Requirements.recompute(scope)
    Requirements.recompute(%{scope | active_working_copy_id: nil})

    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  test "the stale panel recomputes from the domain rather than reading the pass's fingerprints",
       %{conn: conn, scope: scope} do
    {:ok, _view, html} = live(conn, ~p"/dev/graph")

    assert html =~ ~s(data-test="recomputed"),
           "the event path serves and the page still judges it by the pass's fingerprints"

    assert html =~ "agree with the rows being served",
           """
           The recompute panel rendered, but not as agreeing on a freshly seeded
           project. Either a recompute from the domain really differs from the
           seed here — which the exactness tests would also be saying — or the
           panel misreads the report.
           #{inspect(Requirements.served_vs_recomputed(scope))}
           """

    refute html =~ "inputs have moved past",
           "the fingerprint verdict must not be shown beside the oracle"
  end

  # The checkers read through the account — a scope with none is answered
  # nothing by `Questions.list_questions_for_story/2` — so an audit run from
  # the page's bare project id has to be given the account, or it reports a
  # story with an open question as disagreeing with a row that is right.
  # Measured on dev the first time the panel ran: 19 such stories.
  test "a story with an open question is not a disagreement", %{conn: conn, scope: scope} do
    story = CodeMySpec.StoriesFixtures.story_fixture(scope, %{ready_for_dev: true})

    {:ok, _question} =
      CodeMySpec.Questions.create_question(scope, story.id, %{text: "Which account?"})

    :ok = GraphWatcher.settle(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id, [nil, scope.active_working_copy_id])

    {:ok, _view, html} = live(conn, ~p"/dev/graph")

    assert html =~ "agree with the rows being served",
           """
           A story with an open question reads as a disagreement between the
           rows and a recompute of them. The rows say the question is open;
           the recompute was run from a scope with no account and saw none.
           #{inspect(Requirements.served_vs_recomputed(scope))}
           """
  end

  test "waiting metadata disagreement is visible even when satisfaction agrees", %{
    conn: conn,
    scope: scope
  } do
    import Ecto.Query

    CodeMySpec.Repo.update_all(
      from(n in {"project_requirements", CodeMySpec.Requirements.Node},
        where: n.project_id == ^scope.active_project_id and n.name == "personas_complete"
      ),
      set: [details: %{"waiting_on" => "verification probe"}]
    )

    report = Requirements.served_vs_recomputed(scope)
    assert report.disagree > 0
    assert report.actionable_disagree > 0
    assert Enum.any?(report.sample, &String.contains?(&1, "details"))
    {:ok, _view, html} = live(conn, ~p"/dev/graph")
    assert html =~ "graph differs from what is served"
    refute html =~ "Nothing. Every entity's inputs, recomputed now, agree"
  end

  test "an extra served requirement prevents a green audit", %{conn: conn, scope: scope} do
    story = CodeMySpec.StoriesFixtures.story_fixture(scope, %{ready_for_dev: true})
    :ok = GraphWatcher.settle(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id, [nil, scope.active_working_copy_id])
    assert Requirements.served_vs_recomputed(scope).extra == 0

    # A record verdict, stored once per project.
    %CodeMySpec.Requirements.Node{}
    |> Ecto.put_meta(source: "project_requirements")
    |> Ecto.Changeset.change(
      name: "deploy",
      description: "Extra work despite devops being off",
      story_id: story.id,
      satisfied: false
    )
    |> CodeMySpec.Repo.insert!()

    report = Requirements.served_vs_recomputed(scope)
    assert report.extra == 1
    assert report.actionable_disagree > 0
    {:ok, _view, html} = live(conn, ~p"/dev/graph")
    assert html =~ "graph differs from what is served"
    refute html =~ "Nothing. Every entity's inputs, recomputed now, agree"
  end

  test "successful event drains account for the observation they consumed", %{scope: scope} do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info, metadata: [:obs]], fn ->
        GraphInputs.announce(scope, "Verification", [], :this_checkout)
        :ok = IncrementalGraph.settle(scope.active_project_id, [scope.active_working_copy_id])
      end)

    assert log =~ "[IncrementalGraph] accounted for 1 observation(s)"
    assert log =~ "obs="
  end

  test "the drain panel labels failure and unknown work", %{conn: conn, scope: scope} do
    assert_raise RuntimeError, "verification probe", fn ->
      DrainCost.measure(
        %{kind: :event, project_id: scope.active_project_id, observations: 1},
        fn -> raise "verification probe" end
      )
    end

    {:ok, _view, html} = live(conn, ~p"/dev/graph")
    assert html =~ "Failed — partial cost"
    assert html =~ "handled mark/checkouts unknown"
    assert html =~ "fallback mark/checkouts unknown"
  end

  test "the harness panel reports whether a harness has joined, not a watcher nothing starts", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/dev/graph")

    refute html =~ "NOT watched"
    assert html =~ "NOT joined", "no harness joins in a unit test, and the panel should say so"
  end
end
