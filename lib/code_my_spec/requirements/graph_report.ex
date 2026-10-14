defmodule CodeMySpec.Requirements.GraphReport do
  @moduledoc """
  The **cached** requirement graph, with what is needed to tell whether it moved.

  One payload for every surface that serves it — the local app's
  `/api/projects/:project_name/requirements/graph` and the cloud's
  `/api/projects/:project_id/requirements/graph` — so a reader moving from one
  to the other diffs the graph rather than two serializers.

    * `computed_at` — when the served graph was computed. Unchanged across two
      requests means the cache was served; advancing means it was recomputed.
    * `served_from` — `"cache"`, or `"empty"` when nothing has computed this
      vantage yet.
    * `watcher` — whether a writer is serving this project, whether a pass is
      pending, when it last recomputed, and what its last recompute failed
      with. The last is the only way to tell a graph that has not changed from
      one that has stopped being able to.
    * `last_drain` — what the last drain on this project cost, in queries, rows
      and checkouts settled.
    * `vantage` — which row-space answered, and whose tree those rows are about.
    * `nodes` — name, entity, satisfaction, details and freshness stamps.
    * `edges` — prerequisites, as `[entity_type, entity_id, name]` pairs. Nodes
      alone cannot say whether a requirement is gated.

  Deliberately does not settle unless asked. A caller checking whether a write
  moved the graph must see the state as it stands; `settle: false` answers
  from the rows without reconciling the watcher first.
  """

  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

  @doc """
  The graph report for `scope`, read the way an HTTP query asks for it.

  `params` are the request's query params: `"working_copy"` names the checkout
  to read as (none means the project's main copy), and `"settle" => "false"`
  skips reconciling the watcher before reading.
  """
  @spec read(Scope.t(), map()) :: map()
  def read(%Scope{} = scope, params \\ %{}) do
    scope = scope_for(scope, params)
    {nodes, edges, computed_at, served_from} = cached_with_provenance(scope, settle?(params))

    %{
      computed_at: computed_at,
      served_from: served_from,
      watcher: watcher_report(writer_status(scope.active_project_id)),
      last_drain: DrainCost.last(scope.active_project_id, :event),
      vantage: Requirements.vantage_of(scope),
      nodes: Enum.map(nodes, &node_report/1),
      edges: Enum.map(edges, &edge_report/1)
    }
  end

  defp settle?(%{"settle" => "false"}), do: false
  defp settle?(_params), do: true

  # `nil` here means "no rows at this vantage", answered rather than papered
  # over: reads compute nothing, so a second read would return the same.
  defp cached_with_provenance(scope, settle?) do
    case RequirementGraph.cached_graph(scope, settle: settle?) do
      {{nodes, edges}, nil} -> {nodes, edges, nil, "empty"}
      {{nodes, edges}, computed_at} -> {nodes, edges, computed_at, "cache"}
    end
  end

  # A requirement graph is a statement about a checkout. Naming none resolves
  # to the project's main copy (`WorkingCopies.reading_copy_id/1`); `vantage`
  # says which rows answered.
  defp scope_for(scope, %{"working_copy" => id}) when is_binary(id) and id != "",
    do: %{scope | active_working_copy_id: id}

  defp scope_for(scope, _params), do: scope

  @doc """
  The status of the writer a reader is served from, or nil when none is
  running. Inverted, that is the projector — and it has no debounce, so a write
  with nobody reading moves `last_recompute` the moment it lands.

  The requirements graph page shows this too, so the page and this report
  cannot disagree about whether the graph is being kept current.
  """
  @spec writer_status(Ecto.UUID.t()) :: map() | nil
  def writer_status(project_id), do: IncrementalGraph.status(project_id)

  @doc "What to call that writer."
  @spec writer_name() :: String.t()
  def writer_name, do: "projector"

  defp watcher_report(nil), do: %{watching: false}

  defp watcher_report(status) do
    %{
      watching: true,
      pending: Map.get(status, :pending),
      last_recompute: Map.get(status, :last_recompute),
      last_error: error_report(Map.get(status, :last_error))
    }
  end

  defp error_report(nil), do: nil
  defp error_report(%{at: at, message: message}), do: %{at: at, message: message}

  # `entity_name` because an id cannot be recognised; `details` because a
  # verdict alone cannot say why a requirement is open; `inputs_fingerprint`
  # because `checked_at` alone cannot say whether a row is current.
  defp node_report(node) do
    %{
      name: node.name,
      entity_type: node.entity_type,
      entity_id: node.entity_id,
      entity_name: Map.get(node, :entity_name),
      satisfied: node.satisfied,
      details: node.details,
      checked_at: Map.get(node, :checked_at),
      inputs_fingerprint: Map.get(node, :inputs_fingerprint)
    }
  end

  # `Topology.node_key/1`'s own shape, as a list because JSON has no tuple.
  defp edge_report(%{from: from, to: to}), do: %{from: key_report(from), to: key_report(to)}

  defp key_report({entity_type, entity_id, name}), do: [entity_type, to_string(entity_id), name]
end
