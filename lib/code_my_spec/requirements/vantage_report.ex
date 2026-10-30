defmodule CodeMySpec.Requirements.VantageReport do
  @moduledoc """
  What each checkout's graph looks like right now, side by side.

  A verdict is a statement about one checkout, so the graph is nine or ten
  parallel answers rather than one — and until this existed, the only way to
  compare them was `psql`. Both of the routing bugs found on 2026-09-17 were
  invisible from every page: one checkout's answers current and eight frozen
  for two and a quarter hours reads, from any single vantage, exactly like a
  healthy graph.

  So this is the view that makes "which checkouts did that observation move"
  answerable by looking.

  ## Why counts and stamps rather than verdicts

  A per-checkout diff of the verdicts themselves is the expensive question and
  it already has a home — `stale_entities_report/1` runs the full per-entity
  comparison on demand. This is the cheap one, and the cheap one is what was
  missing: row count says whether a checkout is projecting at all, and the
  newest and oldest `checked_at` together say whether it is moving or stuck.

  A checkout whose newest stamp is hours behind its neighbours is the failure
  mode, and it costs two aggregates to see.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Users.Scope

  @type row :: %{
          working_copy_id: Ecto.UUID.t() | nil,
          label: String.t(),
          rows: non_neg_integer(),
          newest: NaiveDateTime.t() | nil,
          oldest: NaiveDateTime.t() | nil
        }

  @doc """
  One row per checkout that holds requirements, newest first.

  The unscoped vantage is included and labelled, because it is a real
  row-space — what a reader with no checkout is answered from — and leaving it
  out of the comparison is how it went unnoticed that it was the *only* one
  being maintained.
  """
  @spec build(Scope.t()) :: [row()]
  def build(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    labels = labels_for(project_id)

    # Rows are stored once per project: one row-space, read by every checkout.
    from(n in {"project_requirements", Node},
      left_join: s in "stories",
      on: s.id == n.story_id,
      left_join: c in "components",
      on: c.id == n.component_id,
      where:
        n.project_id == type(^project_id, :binary_id) or
          s.project_id == type(^project_id, :binary_id) or
          c.project_id == type(^project_id, :binary_id)
    )
    |> select([n], %{
      working_copy_id: nil,
      rows: count(n.id),
      newest: max(n.checked_at),
      oldest: min(n.checked_at)
    })
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :label, label_for(&1.working_copy_id, labels)))
    |> Enum.sort_by(& &1.newest, {:desc, NaiveDateTime})
  end

  def build(%Scope{}), do: []

  defp labels_for(project_id) do
    from(w in "working_copies",
      where: w.project_id == type(^project_id, :binary_id),
      select: {w.id, w.label}
    )
    |> Repo.all()
    |> Map.new(fn {id, label} -> {Ecto.UUID.cast!(id), label} end)
  end

  # `nil` is not missing data. It is the row-space a reader with no checkout
  # reads, and naming it plainly is the point of including it.
  defp label_for(nil, _labels), do: "(no checkout)"
  defp label_for(id, labels), do: Map.get(labels, id) || String.slice(id, 0, 8)
end
