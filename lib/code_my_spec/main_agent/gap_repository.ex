defmodule CodeMySpec.MainAgent.GapRepository do
  @moduledoc """
  Records what the main agent had to cover for, once per gap.

  ## Upsert, not insert-or-check

  `{project, role, capability}` is unique and the count goes up in the same
  statement. Reading first and then writing is the shape that files the second
  issue: two agents hit the same gap in the same second, both read nothing, both
  file. Rare, and rare is how a backlog acquires the duplicate that teaches
  triage to skim.

  ## The issue is attached rather than re-filed

  The row owns whether an issue exists. That is what makes "do not file a second
  issue for the same gap" a property of the data rather than of whoever
  remembers to check — and it is why the count and the issue live together: the
  thing that decides to file is the thing that knows how many times this has
  happened.
  """

  import Ecto.Query

  alias CodeMySpec.MainAgent.CapabilityGap
  alias CodeMySpec.Repo

  @doc """
  Note that the main agent covered for this role's missing capability.

  Returns the gap as it now stands, so the caller can see whether this was the
  first time and how many times it has happened.
  """
  @spec record(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, CapabilityGap.t()} | {:error, Ecto.Changeset.t()}
  def record(project_id, role, capability) do
    %CapabilityGap{}
    |> CapabilityGap.changeset(%{
      project_id: project_id,
      role: to_string(role),
      capability: capability,
      occurrences: 1
    })
    |> Repo.insert(
      on_conflict: [inc: [occurrences: 1]],
      conflict_target: [:project_id, :role, :capability],
      returning: true
    )
  end

  @doc """
  Attach the issue that was filed for this gap, so it is filed once.

  By id rather than through the changeset. The struct this is handed came back
  from an upsert, and running it through `Repo.update/1` re-offers every field
  to the unique index it was just written under — which fails on a row that has
  not moved. Setting one column by primary key cannot.
  """
  @spec attach_issue(CapabilityGap.t(), Ecto.UUID.t()) :: :ok
  def attach_issue(%CapabilityGap{id: id}, issue_id) do
    from(g in CapabilityGap, where: g.id == type(^id, :binary_id))
    |> Repo.update_all(set: [issue_id: issue_id])

    :ok
  end

  @doc "This project's gaps, most bitten first."
  @spec list(Ecto.UUID.t()) :: [CapabilityGap.t()]
  def list(project_id) do
    from(g in CapabilityGap,
      where: g.project_id == type(^project_id, :binary_id),
      order_by: [desc: g.occurrences]
    )
    |> Repo.all()
  end
end
