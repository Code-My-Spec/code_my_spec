defmodule CodeMySpec.Requirements.NodeRepository do
  @moduledoc """
  Writes computed requirement nodes to rows, and reads what they say.

  One upsert per entity type, because the identity is a partial unique index per
  entity type and Postgres wants a concrete conflict target. Splitting on the
  owner is what lets `insert_all` name one.

  ## Why upsert rather than replace

  A node's row id is what edges point at. Deleting and reinserting would issue
  new ids on every graph computation and orphan every edge — so rows persist and
  only the verdict moves.

  That is also why `on_conflict` names its columns instead of `:replace_all`:
  `inserted_at` must survive, and so must the id.

  ## Reading

  These rows plus `requirement_edges` are a read model, and questions about the
  graph's *current* shape can be answered from them without recomputing
  anything. `requirement_details/3` is one such reader; the recompute path
  exists to keep the rows true, not to answer every question about them.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Node, Projection}
  alias CodeMySpec.Users.Scope

  @doc """
  One requirement's recorded `details`, read straight off the row.

  For the stop hook's nudge, which wants a single reason string and used to get
  it by asking for the whole graph — `Requirements.cached_all/1`, which computes
  the project on a cache miss. The stop hook syncs files before it decides, so
  the fingerprint has always just moved and the miss is the normal case: a full
  compute, edges included, to read one `details["reason"]` the row already
  holds. Measured on this project after the incremental recompute shipped, four
  computes in nine minutes on the new build, two of them stop hooks.

  A stop is not a change. Nothing here recomputes.

  Scoped three ways because the rows are, deliberately: `project_id` is set
  only on project-level nodes, so filtering on it alone finds the handful and
  misses every component and story requirement.
  """
  @spec requirement_details(Scope.t(), String.t(), [String.t()]) :: map() | nil
  def requirement_details(%Scope{active_project_id: nil}, _name, _entity_ids), do: nil

  def requirement_details(%Scope{}, _name, []), do: nil

  def requirement_details(%Scope{active_project_id: project_id} = scope, name, entity_ids) do
    wanted = Enum.map(entity_ids, &to_string/1)

    from(n in Node,
      where: n.name == ^to_string(name),
      where:
        n.project_id == ^project_id or
          n.component_id in subquery(
            from(c in "components",
              where: c.project_id == type(^project_id, :binary_id),
              select: c.id
            )
          ) or
          n.issue_id in subquery(
            from(i in CodeMySpec.Issues.Issue, where: i.project_id == ^project_id, select: i.id)
          ) or
          n.story_id in subquery(
            from(s in "stories",
              where: s.project_id == type(^project_id, :binary_id),
              select: s.id
            )
          ),
      select: %{
        details: n.details,
        project_id: n.project_id,
        component_id: n.component_id,
        story_id: n.story_id,
        issue_id: n.issue_id
      }
    )
    |> where(^copy_filter(Projection.vantage(scope)))
    |> Repo.all()
    |> Enum.find(fn row ->
      # All three, because a row names its entity in exactly one of them and
      # leaves the other two null — a project requirement carries `project_id`
      # and no component or story. Matching only the latter two answered "no
      # reason" for every project-level requirement, which is how the nudge
      # went back to naming `technical_strategy` without saying what held it.
      to_string(row.project_id) in wanted or
        to_string(row.component_id) in wanted or
        to_string(row.story_id) in wanted or to_string(row.issue_id) in wanted
    end)
    |> case do
      %{details: details} -> details
      nil -> nil
    end
  end

  @typedoc """
  Which entities this computation looked at, as against which produced nodes.

  The two differ, and conflating them is what let stale rows survive forever.
  """
  @type visited :: %{components: [Ecto.UUID.t()], stories: [integer()]} | nil

  # `is_nil` rather than `== nil`: the UI path's rows carry a null working copy,
  # and `= NULL` is never true in SQL, so comparing that way would match no row
  # and make every UI render insert a fresh duplicate.
  defp copy_filter(nil), do: dynamic([n], is_nil(n.working_copy_id))
  defp copy_filter(id), do: dynamic([n], n.working_copy_id == ^id)
end
