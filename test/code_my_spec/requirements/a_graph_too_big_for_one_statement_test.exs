defmodule CodeMySpec.Requirements.AGraphTooBigForOneStatementTest do
  @moduledoc """
  A graph with more rows than one statement can bind still persists.

  Postgres binds one parameter per column per row, and the wire protocol counts
  them in a 16-bit field — 65535 for the whole statement. An `insert_all` that
  crosses it does not get slower, it refuses, before touching the database:

      postgresql protocol can not handle 71982 parameters, the maximum is 65535

  What made that expensive is that the *write* is what failed. The recompute
  that produced the rows stored nothing, so the next read found the graph stale
  and computed it again, and failed again — 44 failures and 54 full recomputes
  in 45 minutes, measured in web.log.

  It is per **vantage**, not per project, and that is what made it hard to see
  from the outside. Rows are scoped to a working copy, so one project holds one
  graph per checkout, and only the widest crosses the limit. On the project
  this was found on, at three columns an edge:

      9,346 · 9,364 · 9,981 · 14,571 edges  →  28k–43.7k params  →  fits
                          23,994 edges      →  71,982 params     →  refuses

  So the same project logged 34 healthy partial recomputes and 54 full ones
  side by side in the same window, and reading either number alone tells you
  the wrong thing. The four narrow checkouts reused their stored rows exactly
  as intended; the wide one had no stored rows to reuse, because it had never
  once succeeded in writing any.

  The assertion here is not "the rows land" — they land either way at this
  size, and a test that only checks the count passes on the code that broke.
  It is that the work is **split**, which is the thing that was missing. The
  budget is lowered so a boundary can be crossed with six rows rather than
  twenty thousand, because a test that has to build the graph that broke is a
  test nobody runs.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Edge, Node, NodeRepository, Requirement}

  setup do
    # Six parameters a statement: two edge rows at three columns, and — since
    # ten columns will not fit at all — one node row at a time.
    Application.put_env(:code_my_spec, :bind_budget, 6)
    on_exit(fn -> Application.delete_env(:code_my_spec, :bind_budget) end)

    %{scope: full_scope_fixture()}
  end

  defp node(project_id, name) do
    %Requirement{
      entity_type: "project",
      entity_id: project_id,
      name: name,
      description: "#{name} on project",
      satisfied: false,
      details: %{}
    }
  end

  # The handler runs in whichever process emitted the event, and Repo calls run
  # in the caller — so this is the test's own process, and filtering on it keeps
  # the count clean while the rest of the suite runs alongside.
  defp counting_inserts(ref) do
    parent = self()
    handler = "bind-budget-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:code_my_spec, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == parent, do: send(parent, {ref, meta[:source], meta[:query]})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp inserts_into(ref, table) do
    receive do
      {^ref, ^table, query} ->
        if String.starts_with?(query, "INSERT"),
          do: [query | inserts_into(ref, table)],
          else: inserts_into(ref, table)

      {^ref, _other_source, _query} ->
        inserts_into(ref, table)
    after
      0 -> []
    end
  end

  test "edges beyond the budget are written in several statements", %{scope: scope} do
    project_id = scope.active_project_id
    names = for i <- 1..6, do: "budget_edge_node_#{i}"
    keys = NodeRepository.upsert_all(scope, Enum.map(names, &node(project_id, &1)))

    [hub | spokes] = names

    edges =
      for spoke <- spokes do
        %{from: {"project", project_id, hub}, to: {"project", project_id, spoke}}
      end

    ref = make_ref()
    counting_inserts(ref)

    assert {:ok, 5} = NodeRepository.replace_edges(scope, edges, keys)

    statements = inserts_into(ref, "requirement_edges")

    assert length(statements) > 1, """
    Five edge rows at three columns were written in #{length(statements)}
    statement(s) against a budget of six parameters. One statement means the
    budget is not being consulted, which is the shape that refused outright at
    23,994 edges — and refusing the write is what starved the incremental
    recompute, because a partial recompute has nothing to reuse until a full
    one has stored something.
    """

    assert Repo.aggregate(Edge, :count) == 5, "splitting the work must not lose any of it"
  end

  test "nodes beyond the budget are too, and their ids still survive", %{scope: scope} do
    project_id = scope.active_project_id
    names = for i <- 1..4, do: "budget_node_#{i}"
    nodes = Enum.map(names, &node(project_id, &1))

    ref = make_ref()
    counting_inserts(ref)

    keys = NodeRepository.upsert_all(scope, nodes)

    assert length(inserts_into(ref, "requirements")) > 1,
           "ten columns a row means the node table refuses at 6,553 — the narrower " <>
             "of the two limits, and the one nothing would have hit first because " <>
             "edges outnumber nodes"

    assert Repo.aggregate(Node, :count) == 4

    # The property the whole table design rests on: a node's id is what edges
    # point at, so chunking the upsert must not turn one pass into new ids.
    second = NodeRepository.upsert_all(scope, nodes)

    assert second == keys,
           "chunked upserts must keep node ids stable, or every edge written " <>
             "against the first pass is orphaned by the second"
  end
end
