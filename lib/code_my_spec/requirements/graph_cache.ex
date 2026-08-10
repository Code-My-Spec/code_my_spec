defmodule CodeMySpec.Requirements.GraphCache do
  @moduledoc """
  Stores the last computed requirement graph for a project.

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
  def fetch(%Scope{active_project_id: project_id}, fingerprint)
      when is_binary(project_id) and is_binary(fingerprint) do
    CachedGraph
    |> where([g], g.project_id == ^project_id and g.fingerprint == ^fingerprint)
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
      do_publish(project_id, fingerprint, {nodes, edges})
      :published
    end
  end

  # `:unchanged` rather than `:ok` so the caller can hang the node and edge
  # writes off the same fingerprint check. A second `current?/2` would be a
  # second indexed SELECT on a path the UI hits every render, and two checks
  # could disagree.
  def publish(_scope, _fingerprint, _graph), do: :unchanged

  defp current?(scope, fingerprint) do
    match?({:ok, _}, fetch_fingerprint(scope, fingerprint))
  end

  defp fetch_fingerprint(%Scope{active_project_id: project_id}, fingerprint) do
    CachedGraph
    |> where([g], g.project_id == ^project_id and g.fingerprint == ^fingerprint)
    |> select([g], g.id)
    |> Repo.one()
    |> case do
      nil -> :miss
      id -> {:ok, id}
    end
  end

  defp do_publish(project_id, fingerprint, {nodes, edges}) do
    now = DateTime.utc_now()

    attrs = %{
      id: Ecto.UUID.generate(),
      project_id: project_id,
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
      conflict_target: :project_id
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
