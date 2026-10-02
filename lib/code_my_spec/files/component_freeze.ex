defmodule CodeMySpec.Files.ComponentFreeze do
  @moduledoc """
  The one-time freeze of a project's components into records (3aeb66cf,
  step 3).

  Until now a project's components were projections of its files, and what they
  were for was implicit: a component a spec file named was intended
  architecture, one only an implementation named was simply there. The freeze
  writes that down as `provenance` — `:authored` for components a spec names,
  `:discovered` for the rest — marks every edge as authored (edges came only
  from specs, or from tools and proposals, which already mark theirs), and
  stamps the project so it is never frozen again.

  `plan/1` reports what `freeze/1` would do and writes nothing, so a person can
  read the numbers first: a component that exists only because of its spec,
  wrongly marked discovered, is exactly the mistake worth catching by eye.

  ## Live checkouts only

  A spec counts only from a live checkout (`Files.LiveCopies`). Old worktrees keep specs the
  project has since deleted — metric_flow's dead ReviewMetrics component stayed
  alive that way — so a component named only by a stale checkout's spec is
  marked discovered and listed separately for review.

  No sync runs here. The harness keeps components synced, and a sync changing
  live data mid-freeze is what the report exists to avoid; `specs_without_component`
  shows any gap instead.
  """

  import Ecto.Query

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Dependency
  alias CodeMySpec.Files.File
  alias CodeMySpec.Files.LiveCopies
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo

  @type report :: %{
          project_id: String.t(),
          project: String.t(),
          frozen_at: DateTime.t() | nil,
          to_author: [String.t()],
          to_discover: non_neg_integer(),
          already_authored: non_neg_integer(),
          stale_spec_only: [String.t()],
          edges_to_author: non_neg_integer(),
          specs_without_component: [String.t()]
        }

  @doc "What freezing `project_id` would do. Writes nothing."
  @spec plan(String.t()) :: report()
  def plan(project_id) do
    project = Repo.get!(Project, project_id)
    {live, stale} = spec_modules(project_id)

    components =
      Repo.all(
        from(c in Component,
          where: c.project_id == ^project_id,
          select: {c.module_name, c.provenance}
        )
      )

    unmarked = for {name, nil} <- components, do: name
    named = MapSet.new(components, &elem(&1, 0))

    %{
      project_id: project_id,
      project: project.name,
      frozen_at: project.components_authored_at,
      to_author: unmarked |> Enum.filter(&MapSet.member?(live, &1)) |> Enum.sort(),
      to_discover: Enum.count(unmarked, &(not MapSet.member?(live, &1))),
      already_authored: Enum.count(components, &match?({_, :authored}, &1)),
      stale_spec_only:
        unmarked
        |> Enum.filter(&(MapSet.member?(stale, &1) and not MapSet.member?(live, &1)))
        |> Enum.sort(),
      edges_to_author: Repo.aggregate(unmarked_edges(project_id), :count),
      specs_without_component: live |> Enum.reject(&MapSet.member?(named, &1)) |> Enum.sort()
    }
  end

  @doc """
  Freezes `project_id`: marks its unmarked components and edges, and stamps it.
  A project already stamped is left alone.
  """
  @spec freeze(String.t()) :: {:ok, report()} | {:ok, :already_frozen}
  def freeze(project_id) do
    case plan(project_id) do
      %{frozen_at: %DateTime{}} -> {:ok, :already_frozen}
      plan -> Repo.transaction(fn -> write(project_id, plan) end)
    end
  end

  defp write(project_id, plan) do
    unmarked = from(c in Component, where: c.project_id == ^project_id and is_nil(c.provenance))

    unmarked
    |> where([c], c.module_name in ^plan.to_author)
    |> Repo.update_all(set: [provenance: :authored])

    Repo.update_all(unmarked, set: [provenance: :discovered])

    edge_ids = unmarked_edges(project_id) |> select([d], d.id)

    from(d in Dependency, where: d.id in subquery(edge_ids))
    |> Repo.update_all(set: [provenance: :authored])

    from(p in Project, where: p.id == ^project_id)
    |> Repo.update_all(set: [components_authored_at: DateTime.utc_now()])

    plan
  end

  defp unmarked_edges(project_id) do
    from(d in Dependency,
      join: c in Component,
      on: c.id == d.source_component_id,
      where: c.project_id == ^project_id and is_nil(d.provenance)
    )
  end

  # `{live, stale}` module names, by whether a live checkout's spec names them.
  defp spec_modules(project_id) do
    live_ids = LiveCopies.ids(project_id)

    rows =
      Repo.all(
        from(f in File,
          where: f.project_id == ^project_id and f.role == :spec,
          select: {
            fragment("?->'data'->>'module_name'", f.validation_errors),
            f.working_copy_id in ^live_ids
          }
        )
      )

    named = Enum.reject(rows, &is_nil(elem(&1, 0)))
    live = for {name, true} <- named, into: MapSet.new(), do: name
    stale = for {name, false} <- named, into: MapSet.new(), do: name
    {live, stale}
  end
end
