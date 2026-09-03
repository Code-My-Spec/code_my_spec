defmodule CodeMySpec.Requirements.GraphCache do
  @moduledoc """
  Stores the last computed requirement graph for a project.

  ## Being retired

  The graph itself is rows now — `requirements` for the nodes,
  `requirement_edges` for the edges — and `RequirementGraph.cached_graph/1`
  serves those. `Requirements.Projection` reads them. What this table still does
  is hold the **fingerprint**, which is how a reader knows whether the rows are
  current, and a `payload` kept only as a fallback for a graph whose rows were
  never written.

  Three things have to be true before the payload column can go:

    * `[Requirements] the projection does not round-trip` stays quiet across
      real projects — the check runs on every publish, which is every genuine
      change
    * `[Requirements] projection is empty for a payload with N nodes` stops
      appearing, meaning every live project has had its rows written at least
      once
    * nothing reads `fetch/2`'s graph except `served_graph/3`

  The first condition used to name `projection differs from payload`, which
  runs on a cache *hit*. That could not be satisfied, and worse, looked like it
  already was: a hit needs the inputs not to have moved since the last
  computation, so during active development it happens almost never. Measured
  over 6h45m of production logs, that comparison ran **once** — on a projection
  that disagreed about every node count. The criterion was being met by the
  check not running.

  So the evidence moved to the write path, where a publish is by definition a
  real change and the rows were just written. Silence there means the round
  trip was exercised and held.

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

  require Logger

  @doc """
  Return the published graph when it was computed from `fingerprint` — i.e.
  when the snapshot still matches current inputs.

  Note this only certifies the *context* inputs. Requirements whose
  satisfaction is delegated can move without changing the fingerprint, so a
  hit means "nothing the preloader sees has changed", not "this graph is
  certainly current". Good enough to label a UI; not good enough to skip
  computing for an agent.

  `{:ok, {nodes, edges}, computed_at}` on a hit, `:miss` when absent or
  computed from different inputs. `computed_at` rides along for the same reason
  `fetch_any/1` returns it: a reader showing a snapshot should be able to say
  when it was taken, even when it is current.
  """
  @spec fetch(Scope.t(), String.t()) :: {:ok, {list(), list()}, DateTime.t()} | :miss
  def fetch(%Scope{active_project_id: project_id} = scope, fingerprint)
      when is_binary(project_id) and is_binary(fingerprint) do
    CachedGraph
    |> where([g], g.project_id == ^project_id and g.fingerprint == ^fingerprint)
    |> for_copy(scope)
    |> select([g], {g.payload, g.computed_at})
    |> Repo.one()
    |> case do
      nil -> :miss
      {payload, computed_at} -> {:ok, decode(payload), computed_at}
    end
  end

  def fetch(_scope, _fingerprint), do: :miss

  @doc """
  Return whatever is cached, regardless of freshness, with the time it was
  computed.

  For readers that cannot compute — the web UI against a project with no
  harness running. They get the last known graph and enough information to say
  how old it is, rather than an empty page.
  """
  @spec fetch_any(Scope.t()) :: {:ok, {list(), list()}, DateTime.t()} | :miss
  def fetch_any(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    CachedGraph
    |> where([g], g.project_id == ^project_id)
    |> Repo.one()
    |> case do
      nil -> :miss
      row -> {:ok, decode(row.payload), row.computed_at}
    end
  end

  def fetch_any(_scope), do: :miss

  @doc """
  Publish a freshly computed graph. One row per project, replaced in place.

  Failures are logged and swallowed. This is a cache: a project whose graph
  cannot be written still works, one recomputation at a time, and taking down
  an agent's turn because a cache write lost a race would be a worse trade.
  """
  @spec publish(Scope.t(), String.t(), {list(), list()}) :: :ok
  def publish(%Scope{active_project_id: project_id} = scope, fingerprint, {nodes, edges})
      when is_binary(project_id) and is_binary(fingerprint) do
    if current?(scope, fingerprint) do
      # Nothing moved since the last publish. Readers call compute_graph/1 too —
      # the web UI does, on every render — so writing unconditionally would mean
      # a ~30KB upsert per page view for a row that already says the same thing.
      # One indexed SELECT is the cheaper half of that trade.
      :unchanged
    else
      do_publish(project_id, scope.active_working_copy_id, fingerprint, {nodes, edges})
      :published
    end
  end

  # `:unchanged` rather than `:ok` so the caller can hang the node and edge
  # writes off the same fingerprint check. A second `current?/2` would be a
  # second indexed SELECT on a path the UI hits every render, and two checks
  # could disagree.
  def publish(_scope, _fingerprint, _graph), do: :unchanged

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

  defp do_publish(project_id, working_copy_id, fingerprint, {nodes, edges}) do
    now = DateTime.utc_now()

    attrs = %{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      working_copy_id: working_copy_id,
      fingerprint: fingerprint,
      payload: encode({nodes, edges}),
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
           :payload,
           :node_count,
           :edge_count,
           :computed_by,
           :computed_at,
           :updated_at
         ]},
      conflict_target: [:project_id, :working_copy_id]
    )

    :ok
  rescue
    error ->
      Logger.warning("[GraphCache] write failed: #{inspect(error)}")
      :ok
  end

  # term_to_binary rather than JSON: nodes are Requirement structs and edge
  # endpoints are `{entity_type, entity_id, name}` tuples. A JSON codec for
  # those is hand-written, and its bugs would surface as the agent being handed
  # a malformed requirement rather than as a decode error. Compression is worth
  # it — the payload is mostly repeated requirement names and entity ids.
  defp encode(graph), do: :erlang.term_to_binary(graph, compressed: 6)

  defp decode(payload), do: :erlang.binary_to_term(payload, [:safe])

  # `node()` is the BEAM node name, which for a sprite is set per container.
  defp computed_by, do: to_string(node())
end
