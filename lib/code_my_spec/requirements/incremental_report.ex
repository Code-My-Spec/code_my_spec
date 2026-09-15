defmodule CodeMySpec.Requirements.IncrementalReport do
  @moduledoc """
  What the rows say about whether the graph recomputes incrementally.

  "Incremental sync works" was, until this existed, a claim supported by log
  lines and believed. The counts in those lines cannot carry it: `recomputed 63
  of 2078 requirements` is one pass's own account of itself, scrolled past in a
  file, and a reader who wants to know whether the last hour was incremental
  has to reconstruct it by grepping and adding up.

  The rows can answer it directly, and they are the thing being claimed about.
  Every pass stamps `checked_at` on exactly the entities it recomputed and
  leaves every other row untouched — that is what `recompute_stale/3` does and
  the whole of what "incremental" means here. So the size of each distinct
  `checked_at` group *is* the size of a pass, measured from the result rather
  than from the report:

      14:31:02   3 of 2,078 rows      <- one story moved
      14:28:41   7 of 2,078 rows      <- a component family
      13:02:15   2,078 of 2,078 rows  <- a full rebuild

  A column of small numbers is the claim. A column of full-height ones means
  something is invalidating everything, and the page says which pass rather
  than leaving it to be inferred.

  Two things it deliberately does not do. It does not compute anything — every
  number is read from rows that already exist, so opening the page cannot
  produce the freshness it is reporting on, which is the mistake the whole
  branch exists to remove. And it does not read logs: `mix cms.graph_observations`
  already proves the other half (that every announcement reached a recompute)
  from a log set, and duplicating it here would be a second answer free to
  drift from the first.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{GraphWatcher, Node, Projection, RequirementGraph}
  alias CodeMySpec.Users.Scope

  @type pass :: %{at: NaiveDateTime.t(), rows: non_neg_integer(), share: float()}

  @type t :: %{
          watcher: map() | nil,
          total_rows: non_neg_integer(),
          vantages: [map()],
          passes: [pass()],
          stale_read_log: boolean()
        }

  @doc """
  The report for one project, read entirely from rows.

  `limit` bounds the passes shown; the default is a screenful rather than a
  history, because the question is "is it incremental now".
  """
  @spec build(Scope.t(), keyword()) :: t()
  def build(%Scope{active_project_id: project_id} = scope, opts \\ [])
      when is_binary(project_id) do
    limit = Keyword.get(opts, :limit, 25)
    rows = owned_rows(project_id)
    total = Repo.aggregate(rows, :count)

    %{
      watcher: GraphWatcher.status(project_id),
      total_rows: total,
      vantages: vantages(rows, scope),
      passes: passes(rows, total, limit),
      stale_read_log: RequirementGraph.stale_read_logging?()
    }
  end

  # Every requirement row belonging to this project, whichever of the three
  # owners it hangs off. A row has exactly one, so the three clauses are
  # disjoint and no row is counted twice.
  defp owned_rows(project_id) do
    from(n in Node,
      left_join: s in "stories",
      on: s.id == n.story_id,
      left_join: c in "components",
      on: c.id == n.component_id,
      where:
        n.project_id == type(^project_id, :binary_id) or
          s.project_id == type(^project_id, :binary_id) or
          c.project_id == type(^project_id, :binary_id)
    )
  end

  # Rows per vantage, with how fresh the freshest row in each is.
  #
  # A vantage that has stopped moving while its neighbours advance is the
  # visible form of a watcher maintaining one checkout's row-space and no
  # others — which is a real failure this branch fixed and which nothing
  # surfaced at the time.
  defp vantages(rows, scope) do
    counted =
      rows
      |> group_by([n], n.working_copy_id)
      |> select([n], {n.working_copy_id, count(n.id), max(n.checked_at)})
      |> Repo.all()
      |> Map.new(fn {vantage, count, newest} -> {vantage, {count, newest}} end)

    scope
    |> Projection.vantages()
    |> Enum.concat(Map.keys(counted))
    |> Enum.uniq()
    |> Enum.map(fn vantage ->
      {count, newest} = Map.get(counted, vantage, {0, nil})
      %{vantage: vantage, rows: count, newest: newest}
    end)
    |> Enum.sort_by(& &1.rows, :desc)
  end

  # One entry per distinct `checked_at`, newest first — which is one entry per
  # pass, because a pass stamps every row it wrote with the same instant.
  #
  # `share` is of the project's whole row count rather than of the vantage's,
  # deliberately: the question a reader has is "did this pass rebuild the
  # project", and a pass that rebuilt one checkout entirely should read as
  # large even though it left the others alone.
  defp passes(rows, total, limit) do
    rows
    |> group_by([n], n.checked_at)
    |> select([n], {n.checked_at, count(n.id)})
    |> order_by([n], desc: n.checked_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reject(fn {at, _count} -> is_nil(at) end)
    |> Enum.map(fn {at, count} -> %{at: at, rows: count, share: share(count, total)} end)
  end

  defp share(_count, 0), do: 0.0
  defp share(count, total), do: count / total
end
