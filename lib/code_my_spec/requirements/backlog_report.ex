defmodule CodeMySpec.Requirements.BacklogReport do
  @moduledoc """
  What is queued and has not been applied, grouped by who wrote it.

  A mark is durable on purpose — it outlives the process that has to act on it,
  so a crash cannot lose the work. The cost of that is a queue nobody could
  see: on 2026-09-17 the projector raised on every drain for twenty minutes and
  the backlog grew from 31 to 610 marks, and the only way to watch it was to
  count rows by hand.

  A growing number here means drains are failing or falling behind. A flat
  non-zero number means the same thing more quietly.

  ## Why grouped by source and scope

  Those two columns answer the question that decides what a drain will cost.
  `entity_scope` is `entity` when the writer named what it moved, `project`
  when it named the project, and `unknown` when it could not say — and an
  `unknown` mark is read as the whole project at every checkout, which is the
  expensive path. Seeing which writers are producing them is how you find the
  ones that still need narrowing.

  `kind` distinguishes an event, which a handler may be able to apply, from a
  bare invalidation, which can only be recomputed.

  ## Why the checkout is grouped on too

  `entity_scope` and `working_copy_id` are two different narrowings and a mark
  can be narrow on one and wide on the other. An analyzer completing names the
  checkout it ran on and no entities at all — correct on both counts, since a
  run reports about a tree rather than about a list of components — so it shows
  as `unknown` scope on a perfectly well-routed mark.

  Reading one and assuming the other is how criterion 3507 was misdiagnosed:
  the entity scope said `unknown` and the checkout said exactly the right
  thing. They are grouped separately so the page cannot be read that way.

  It is also the operational question. A queue that will not drain is usually
  one worktree generating marks, and "which checkout" is the first thing worth
  knowing about it.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Invalidation
  alias CodeMySpec.Users.Scope

  @type row :: %{
          source: String.t(),
          kind: String.t() | nil,
          entity_scope: String.t(),
          count: non_neg_integer(),
          oldest: NaiveDateTime.t() | nil
        }

  @doc "Pending marks for this project, heaviest group first."
  @spec build(Scope.t()) :: %{total: non_neg_integer(), groups: [row()]}
  def build(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    groups =
      Invalidation
      |> where([i], i.project_id == ^project_id)
      |> group_by([i], [i.source, i.kind, i.entity_scope, i.working_copy_id])
      |> select([i], %{
        source: i.source,
        kind: i.kind,
        entity_scope: i.entity_scope,
        working_copy_id: i.working_copy_id,
        count: count(i.id),
        oldest: min(i.inserted_at)
      })
      |> Repo.all()
      |> Enum.sort_by(& &1.count, :desc)

    %{total: Enum.sum(Enum.map(groups, & &1.count)), groups: groups}
  end

  def build(%Scope{}), do: %{total: 0, groups: []}
end
