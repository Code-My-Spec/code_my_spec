defmodule CodeMySpec.Requirements.CopyGraph.Equivalence do
  @moduledoc """
  The cut-over gate's check: at every copy that has reported an overlay, and at
  `nil`, does `CopyGraph.load/2` serve the graph `Projection.load/2` serves?
  Reads only, so it runs against a live server (`run_script`).

  Deleted with the per-copy projection.
  """

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.CopyGraph
  alias CodeMySpec.Requirements.CopyOverlay.Report
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.Topology
  alias CodeMySpec.Requirements.Verification
  alias CodeMySpec.Users.Scope

  @samples 3

  @doc """
  One report per vantage: counts in `Verification.clean?/1`'s shape, plus a
  few disagreeing node keys with the fields that differ.
  """
  @spec check(Scope.t()) :: %{(Ecto.UUID.t() | nil) => map()}
  def check(%Scope{active_project_id: project_id} = scope) do
    copies =
      Repo.all(from(r in Report, where: r.project_id == ^project_id, select: r.working_copy_id))

    Map.new([nil | copies], fn copy ->
      {copy, compare(%{scope | active_working_copy_id: copy})}
    end)
  end

  @doc "Whether every vantage `check/1` reported agrees."
  @spec clean?(map()) :: boolean()
  def clean?(reports),
    do: Enum.all?(reports, fn {_copy, report} -> Verification.clean?(report) end)

  defp compare(scope) do
    ctx = Preloader.read_context(scope)
    {stored, stored_edges} = Projection.load(scope, ctx)
    {read, read_edges} = CopyGraph.load(scope, ctx)

    stored = behaviour(stored)
    read = behaviour(read)
    disagree = for {key, node} <- stored, Map.has_key?(read, key), read[key] != node, do: key
    stored_edges = edge_set(stored_edges)
    read_edges = edge_set(read_edges)

    %{
      nodes: map_size(stored),
      missing: length(Map.keys(stored) -- Map.keys(read)),
      extra: length(Map.keys(read) -- Map.keys(stored)),
      disagree: length(disagree),
      edges_missing: MapSet.size(MapSet.difference(stored_edges, read_edges)),
      edges_extra: MapSet.size(MapSet.difference(read_edges, stored_edges)),
      samples:
        for key <- Enum.take(disagree, @samples) do
          {key, Verification.changed_fields(stored[key], read[key])}
        end
    }
  end

  defp behaviour(nodes), do: Map.new(nodes, &{Topology.node_key(&1), Verification.behavior(&1)})

  defp edge_set(edges), do: MapSet.new(edges, &{&1.from, &1.to})
end
