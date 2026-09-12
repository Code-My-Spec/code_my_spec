defmodule CodeMySpec.Requirements.GraphCache do
  @moduledoc """
  Stores the last computed requirement graph for a project.

  ## What it holds, now that the payload is gone

  The graph itself is rows — `requirements` for the nodes, `requirement_edges`
  for the edges — and `Requirements.Projection` reads them. This table holds the
  **fingerprint**, which is how a reader knows whether those rows are current,
  and the counts the publish recorded.

  It used to hold a `payload` as well: the whole graph as an Erlang term, served
  as a fallback for a graph whose rows were never written. Retiring it was
  conditional on three things, all since met — `the projection does not
  round-trip` staying quiet across real projects, `projection is empty for a
  payload` no longer appearing, and nothing reading the graph out of `fetch/2`
  except the one caller that served it.

  The first condition originally named a comparison that runs on a cache *hit*,
  which could not be satisfied and looked like it already was: a hit needs the
  inputs not to have moved since the last computation, so during active
  development it happens almost never. Measured over 6h45m of production logs,
  that comparison ran **once** — on a projection that disagreed about every node
  count. The criterion was being met by the check not running.

  So the evidence moved to the write path, where a publish is by definition a
  real change and the rows were just written. 828 computations across four
  rotated logs, silent throughout.

  `node_count` survives the payload because it answers the one thing rows cannot
  say about themselves: that there should be some. Rows that are empty where the
  publish counted nodes were never written, and `RequirementGraph.served_graph/3`
  treats that as a miss rather than serving an empty graph.

    The fingerprint half stays regardless. It answers "are these rows current",
  which the rows cannot answer about themselves.

  A published snapshot, not a memoization. Computation never reads it, so
  there is no cache key that can be wrong — the graph a reader gets is one that
  was genuinely computed, and the fingerprint tells them whether the inputs
  have moved since.

  It is not a memoization because it cannot safely be one yet: 13 requirement
  definitions delegate satisfaction to modules that read deploys, QA results
  and issues, none of which the preloader loads. See
  `RequirementGraph.compute_and_publish/3`.

  Two readers want the graph and only one of them can afford to compute it.
  The agent's harness holds the inputs — Files and Problems are produced where
  the working copy is — and recomputing there costs ~170ms on a 1000-file
  project. The web UI holds none of them and may be looking at a project whose
  harness is not running at all.

  So the graph is written by whoever computed it and read by everyone. A reader
  that cannot compute serves the cached graph and says when it was computed; a
  reader that can compares fingerprints and recomputes on a miss.

  A stale row is never served: `fetch/2` takes the fingerprint the caller
  expects and answers `:miss` on mismatch. Staleness is a cache miss, not a
  wrong answer — which matters because the wrong answer here is the agent being
  told to work on something already done.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.CachedGraph
  alias CodeMySpec.Users.Scope

  @doc """
  Whether the published rows were computed from `fingerprint` — i.e. whether
  the snapshot still matches current inputs.

  Note this only certifies the *context* inputs. Requirements whose
  satisfaction is delegated can move without changing the fingerprint, so a
  hit means "nothing the preloader sees has changed", not "this graph is
  certainly current". Good enough to label a UI; not good enough to skip
  computing for an agent.

  `{:ok, node_count, computed_at}` on a hit, `:miss` when absent or computed
  from different inputs.

  The graph is not here to return — it is the `requirements` and
  `requirement_edges` rows, which `Projection.load/2` reads. What comes back
  instead is what the caller cannot get from those rows: when they were computed,
  so a reader showing a snapshot can say how old it is, and how many nodes the
  publish wrote, so a reader finding none can tell "nothing to do" from "the
  write did not land".
  """
  @spec fetch(Scope.t(), String.t()) :: {:ok, non_neg_integer(), DateTime.t()} | :miss
  def fetch(%Scope{active_project_id: project_id} = scope, fingerprint)
      when is_binary(project_id) and is_binary(fingerprint) do
    CachedGraph
    |> where([g], g.project_id == ^project_id and g.fingerprint == ^fingerprint)
    |> for_copy(scope)
    |> select([g], {g.node_count, g.computed_at})
    |> Repo.one()
    |> case do
      nil -> :miss
      {node_count, computed_at} -> {:ok, node_count || 0, computed_at}
    end
  end

  def fetch(_scope, _fingerprint), do: :miss

  @doc """
  Publish a freshly computed graph. One row per project and working copy,
  replaced in place.

  Answers `:published` when the row was written and `:unchanged` when the
  fingerprint had not moved. A write that fails raises.

  This used to log the failure and answer `:ok`, on the reasoning that a cache
  a project can live without should not take down an agent's turn over a lost
  race. Two things were wrong with it. There is no race to lose — the write is
  a single `insert_all` with `on_conflict` against the index that would collide
  — so the only failures left are constraint and schema errors, which are bugs.
  And the caller does not treat this as a cache it can live without:
  `RequirementGraph.persist_projection/5` keys the node and edge writes off this
  return value, so answering `:published` for a row that was never written told
  it a fingerprint check had been recorded that had not been.
  """
  @spec publish(Scope.t(), String.t(), {list(), list()}, String.t() | nil) ::
          :published | :unchanged
  def publish(scope, fingerprint, graph, topology_fingerprint \\ nil)

  def publish(
        %Scope{active_project_id: project_id} = scope,
        fingerprint,
        {nodes, edges},
        topology_fingerprint
      )
      when is_binary(project_id) and is_binary(fingerprint) do
    if current?(scope, fingerprint) do
      # Nothing moved since the last publish. Readers call compute_graph/1 too —
      # the web UI does, on every render — so writing unconditionally would be a
      # row rewrite per page view to say what the row already says, and would
      # move `computed_at` to now on a graph that was computed much earlier.
      :unchanged
    else
      do_publish(
        project_id,
        scope.active_working_copy_id,
        fingerprint,
        {nodes, edges},
        topology_fingerprint
      )

      :published
    end
  end

  # `:unchanged` rather than `:ok` so the caller can hang the node and edge
  # writes off the same fingerprint check. A second `current?/2` would be a
  # second indexed SELECT on a path the UI hits every render, and two checks
  # could disagree.
  def publish(_scope, _fingerprint, _graph, _topology_fingerprint), do: :unchanged

  @doc """
  The shape the stored edges describe, or `nil` if the row does not say.

  Read before a partial recompute decides whether it may keep the edges it
  already has. `nil` — a graph published before this was recorded — reads as
  "no basis to reuse", which costs one edge computation and records the answer.
  """
  @spec topology_fingerprint(Scope.t()) :: String.t() | nil
  def topology_fingerprint(%Scope{active_project_id: project_id} = scope)
      when is_binary(project_id) do
    CachedGraph
    |> where([g], g.project_id == ^project_id)
    |> for_copy(scope)
    |> select([g], g.topology_fingerprint)
    |> Repo.one()
  end

  def topology_fingerprint(_scope), do: nil

  # One checkout's cache row, not the project's.
  #
  # The graph this caches is computed from one checkout's files —
  # `Preloader.load/1` scopes them and warns when it cannot — and
  # `NodeRepository.upsert_all/2` already writes and deletes per copy for
  # exactly that reason. The cache kept the project grain, so a publish by one
  # checkout made another checkout's computation answer `:unchanged`, and
  # `persist_projection/5` wrote nothing for it: the second checkout ended up
  # with no requirement rows at all and read the first one's verdict about files
  # it does not have. Issue `5b538c8b`.
  #
  # `is_nil` rather than `== ^nil`, so the blended UI vantage matches its own row
  # instead of matching nothing.
  defp for_copy(query, %Scope{active_working_copy_id: nil}),
    do: where(query, [g], is_nil(g.working_copy_id))

  defp for_copy(query, %Scope{active_working_copy_id: working_copy_id}),
    do: where(query, [g], g.working_copy_id == ^working_copy_id)

  defp current?(scope, fingerprint) do
    match?({:ok, _}, fetch_fingerprint(scope, fingerprint))
  end

  defp fetch_fingerprint(%Scope{active_project_id: project_id} = scope, fingerprint) do
    CachedGraph
    |> where([g], g.project_id == ^project_id and g.fingerprint == ^fingerprint)
    |> for_copy(scope)
    |> select([g], g.id)
    |> Repo.one()
    |> case do
      nil -> :miss
      id -> {:ok, id}
    end
  end

  defp do_publish(project_id, working_copy_id, fingerprint, {nodes, edges}, topology_fingerprint) do
    now = DateTime.utc_now()

    attrs = %{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      working_copy_id: working_copy_id,
      fingerprint: fingerprint,
      topology_fingerprint: topology_fingerprint,
      node_count: length(nodes),
      edge_count: length(edges),
      computed_by: computed_by(),
      computed_at: now,
      inserted_at: DateTime.truncate(now, :second),
      updated_at: DateTime.truncate(now, :second)
    }

    Repo.insert_all(CachedGraph, [attrs],
      on_conflict:
        {:replace,
         [
           :fingerprint,
           :topology_fingerprint,
           :node_count,
           :edge_count,
           :computed_by,
           :computed_at,
           :updated_at
         ]},
      conflict_target: [:project_id, :working_copy_id]
    )

    :ok
  end

  # `node()` is the BEAM node name, which for a sprite is set per container.
  defp computed_by, do: to_string(node())
end
