defmodule CodeMySpecLocalWeb.RequirementsController do
  @moduledoc """
  LLM API for project requirements status.

  Returns markdown responses from the computed requirement graph.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpecLocalWeb.RequirementsMarkdown

  @doc """
  The **cached** graph, with what is needed to tell whether it moved.

  `index/2` answers from the rows like everything else now, so it cannot show
  cache behaviour either — it has no way to distinguish a graph that is current
  from one nobody has recomputed. That is right for an agent asking what to
  work on and useless for anyone asking whether the cache is being served, which
  is a question the system otherwise answers nowhere: `RequirementsLive`
  discards `computed_at`, and the only surface carrying watcher state is
  `/dev/state`, which exists solely under `dev_routes` and therefore not in
  test.

  So this returns JSON rather than markdown, and carries the diagnostics rather
  than only the answer:

    * `computed_at` — when the served graph was computed. Unchanged across two
      requests means the cache was served; advancing means it was recomputed.
    * `watcher` — whether a watcher is running, whether a pass is pending, when
      it last recomputed, and what its last recompute failed with. The last of
      those is the only way to tell a graph that has not changed from one that
      has stopped being able to.
    * `nodes` — name, entity, and satisfaction, which is what a caller
      comparing two answers actually diffs.

  Deliberately does not settle first. A caller wanting the post-settle answer
  can ask for one; a caller checking whether a write moved the graph must be
  able to see the state as it stands, and settling would erase the distinction
  being observed.
  """
  def graph(conn, params) do
    scope = scope_for(conn.assigns.current_scope, params)
    {nodes, edges, computed_at, served_from} = cached_with_provenance(scope, settle?(params))

    json(conn, %{
      computed_at: computed_at,
      served_from: served_from,
      watcher: watcher_report(GraphWatcher.status(scope.active_project_id)),
      # What the last drain on this project cost. Here for the same reason
      # `inputs_fingerprint` is on every node: "an observation costs work in
      # proportion to what it changed" is a claim about numbers, and one whose
      # evidence lives only in a log line cannot be asserted against from
      # outside. Queries, rows and checkouts settled — not milliseconds, which
      # measure the machine rather than the work.
      last_drain: DrainCost.last(scope.active_project_id),
      # Which row-space answered, and whose tree those rows are about. Two
      # facts, and a reader naming no checkout is where they differ: it is
      # answered from the rows kept under no working copy, computed from the
      # project's main checkout's files. Without this the graph carried the
      # answers and nothing saying what they were an answer *about*.
      vantage: Requirements.vantage_of(scope),
      nodes: Enum.map(nodes, &node_report/1),
      # The other half of the graph. Nodes alone cannot answer whether a
      # requirement is *gated* — prerequisites live entirely in
      # `requirement_edges`, and a set of nodes with no edges between them looks
      # identical to a correct graph from every surface that reads only nodes.
      #
      # That is not hypothetical: computing an arriving story's requirements
      # without rebuilding its edges produced seven requirements and no
      # ordering, so `bdd_specs_passing` stopped waiting on `bdd_specs_exist`
      # and every one of them was offered at once. Nothing failed; the graph was
      # just wrong. Criterion 3616 is the claim, and this is what makes it
      # checkable from outside.
      edges: Enum.map(edges, &edge_report/1)
    })
  end

  # `nil` here means "no rows at this vantage", and it is answered rather than
  # papered over.
  #
  # This used to read a second time when the first came back nil, because a
  # miss computed its own answer and reported nil while doing it — so the
  # second read hit the store the first had just filled. Reads compute nothing
  # now, so a second one returns exactly what the first did and the only thing
  # it adds is another preload.
  #
  # `"empty"` rather than `"computed"` for the same reason: nothing computed
  # anything. A vantage with no rows has not been computed *by anybody yet*,
  # which is a different and more alarming answer than "this read built it".
  # `?settle=false` answers from the rows without reconciling the watcher first.
  #
  # Reading normally settles, and `GraphWatcher.settle/2` remembers the vantage
  # the reader named — so asking what a checkout currently holds queues a
  # computation for that checkout. That is right for an agent about to act on
  # the answer and wrong for anything *observing*: criterion 3507 asks whether
  # an analyzer run on one checkout left another alone, and reading the other
  # one to find out was itself causing the recompute it was checking for.
  #
  # Read-only either way. This only chooses whether to reconcile first.
  defp settle?(%{"settle" => "false"}), do: false
  defp settle?(_params), do: true

  defp cached_with_provenance(scope, settle?) do
    case RequirementGraph.cached_graph(scope, settle: settle?) do
      {{nodes, edges}, nil} -> {nodes, edges, nil, "empty"}
      {{nodes, edges}, computed_at} -> {nodes, edges, computed_at, "cache"}
    end
  end

  # A requirement graph is a statement about a checkout, so a question about a
  # particular copy has to name one: `?working_copy=<id>` asks what that copy's
  # agents would ask.
  #
  # Naming none is not a blend. It used to be — a file present in one checkout
  # and absent in another read as present — and since 2026-09-17 it resolves to
  # the project's main copy, `WorkingCopies.reading_copy_id/1`. The `vantage`
  # key on the response says which rows answered and whose tree they are about,
  # because those are two facts and this is the request where they differ.
  defp scope_for(scope, %{"working_copy" => id}) when is_binary(id) and id != "",
    do: %{scope | active_working_copy_id: id}

  defp scope_for(scope, _params), do: scope

  defp watcher_report(nil), do: %{watching: false}

  defp watcher_report(status) do
    %{
      watching: true,
      pending: Map.get(status, :pending),
      last_recompute: Map.get(status, :last_recompute),
      last_error: error_report(Map.get(status, :last_error))
    }
  end

  # A failed recompute leaves every reader served the last good answer, which
  # looks correct and is frozen. Without this, the only way to notice is to
  # compare `last_recompute` against a change you already knew about.
  defp error_report(nil), do: nil
  defp error_report(%{at: at, message: message}), do: %{at: at, message: message}

  # `checked_at` per node, not only `computed_at` for the graph.
  #
  # "An observation recomputes what it touched and leaves the rest" is a
  # question about individual requirements, and one timestamp for the whole
  # graph cannot answer it — every node moves together whether or not the work
  # was necessary. A reader comparing these across two reads can see which
  # requirements actually cost something.
  #
  # `nil` means the node was computed on this request rather than read back.
  # `entity_name` because an id cannot be recognised. This is the diagnostic
  # surface for "is the graph current", and answering that means saying which
  # requirement moved on which thing — `MyApp.Accounts`, not
  # `fdc9c205-f9b7-596c-bcf1-8373b01b6059`. A reader holding only ids has to
  # resolve every one against the database to find out whether the row it cares
  # about is in the list.
  defp node_report(node) do
    %{
      name: node.name,
      entity_type: node.entity_type,
      entity_id: node.entity_id,
      entity_name: Map.get(node, :entity_name),
      satisfied: node.satisfied,
      # Why it is open, in the checker's own words. A verdict alone cannot
      # distinguish "nothing happened" from "something happened and this
      # requirement needs one more thing" — `three_amigos_complete` stays false
      # whether a story has no scenarios at all or is one seal away.
      details: node.details,
      checked_at: Map.get(node, :checked_at),
      # When it was computed, and from what. `checked_at` alone cannot say
      # whether a row is current — only that somebody looked at some point — and
      # this is the stamp the answer actually turns on: `stale_entities/3`
      # compares it against what the entity's sources hash to right now, and
      # recomputes on a mismatch.
      #
      # Without it the rule "a requirement's freshness is decided by the sources
      # it was computed from" is unobservable from outside: two rows with the
      # same `checked_at` may have been computed from different inputs, and a row
      # that should have moved and did not is indistinguishable from one that had
      # no reason to. Criterion 3427 is that claim, and this is what makes it
      # checkable by a reader rather than only by a query.
      inputs_fingerprint: Map.get(node, :inputs_fingerprint)
    }
  end

  # `{entity_type, entity_id, name}` — `Topology.node_key/1`'s own shape, as a
  # list because JSON has no tuple. The same three fields `node_report/1`
  # already emits, so a reader can join the two without an id it has no other
  # use for.
  defp edge_report(%{from: from, to: to}), do: %{from: key_report(from), to: key_report(to)}

  defp key_report({entity_type, entity_id, name}), do: [entity_type, to_string(entity_id), name]

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)
    actionable = RequirementGraph.next_actionable(scope)

    markdown =
      RequirementsMarkdown.index(%{
        project: scope.active_project,
        nodes: nodes,
        actionable: actionable
      })

    text(conn, markdown)
  end

  def show(conn, %{"name" => name}) do
    scope = conn.assigns.current_scope
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)

    node =
      Enum.find(nodes, fn n ->
        n.entity_type == "project" and n.name == name
      end)

    if node do
      markdown = RequirementsMarkdown.show(%{node: node})
      text(conn, markdown)
    else
      conn |> put_status(404) |> text("Requirement not found: #{name}")
    end
  end

  def prompt(conn, %{"name" => name}) do
    scope = conn.assigns.current_scope
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)

    node =
      Enum.find(nodes, fn n ->
        n.entity_type == "project" and n.name == name
      end)

    cond do
      is_nil(node) ->
        conn |> put_status(404) |> text("Requirement not found: #{name}")

      is_nil(node.satisfied_by) ->
        conn |> put_status(400) |> text("No task module for requirement: #{name}")

      true ->
        task = %{project_id: scope.active_project_id}
        {:ok, prompt_text} = node.satisfied_by.command(scope, task)
        text(conn, prompt_text)
    end
  end

  def child(conn, %{"name" => _name, "child_id" => child_id}) do
    scope = conn.assigns.current_scope
    mod = ProjectSetup.find_step(child_id)

    if mod do
      case mod.command(scope, %{}) do
        {:ok, prompt_text} -> text(conn, prompt_text)
        {:error, reason} -> conn |> put_status(500) |> text("Error: #{inspect(reason)}")
      end
    else
      conn |> put_status(404) |> text("Step not found: #{child_id}")
    end
  end
end
