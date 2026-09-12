defmodule CodeMySpec.Requirements.Projection do
  @moduledoc """
  Reads the requirement graph back out of rows.

  The counterpart to `NodeRepository`, and the thing that decides whether rows
  can replace `requirement_graphs.payload`. If a graph read from rows differs
  from the one just computed, the rows are not carrying the graph and no reader
  should be moved onto them.

  ## What is stored and what is rehydrated

  A row holds identity and verdict — `satisfied`, `details`, and which entity it
  belongs to. Everything else on a node comes back from the
  `RequirementDefinition` by name (`scope`, `execution_type`, `validation_type`,
  `orchestrated_by`, `role`, `satisfied_by`, `render_command_always?`,
  `prerequisites`) or from the entity (`entity_name`).

  That split is deliberate. Persisting the definition fields would keep a second
  copy of the definition table in every row, and the copy would be the stale one
  the day a definition changes — a rename would need a backfill, and until it ran
  the graph would describe requirements that no longer exist under names nobody
  uses.

  ## Nodes this projection cannot rehydrate

  A row whose `name` matches no definition for its entity type is dropped rather
  than guessed at. It means the definitions moved and the rows have not caught
  up, which is a real condition — the old node genuinely is not in the graph any
  more — and inventing a node from a row would put it back.
  """

  import Ecto.Query

  alias CodeMySpec.Files.File
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Edge, Node, Registry, Requirement}
  alias CodeMySpec.Users.Scope

  @doc """
  The graph as `{nodes, edges}`, in the same shape `compute_graph/1` returns.
  """
  @spec load(Scope.t(), map()) :: {[Requirement.t()], [map()]}
  def load(%Scope{active_project_id: project_id} = scope, ctx) do
    rows = project_rows(project_id, vantage(scope), ctx)
    nodes = rows |> Enum.map(&rehydrate(&1, ctx)) |> Enum.reject(&is_nil/1)

    by_id = Map.new(rows, &{&1.id, &1})
    {nodes, edges_for(rows, by_id, ctx)}
  end

  @doc """
  Whose view of the project this read is.

  Satisfaction is stored per working copy because that is what it has always
  been — `Preloader.load/1` scopes its file query to one checkout, so every
  verdict is a statement about what that checkout could see. Reading therefore
  has to name a checkout too, and a reader that does not gets one row per copy
  per node with `Map.new/2` keeping whichever came last.

  An agent reads as itself: it must not be told a spec exists because some other
  worktree has one, which is the over-satisfaction `Preloader`'s moduledoc
  measured at 303 skipped specs.

  Anything that is not a checkout reads as the project's **default working
  copy** — in practice the main checkout, the one being pushed to while agents
  work in worktrees off it. That makes it the main-branch view without anything
  having to fetch main, and it is a tree that actually existed, which a union of
  checkouts is not.

  A project that has named no default falls back to the unscoped row. That row
  is the blended computation and it over-satisfies; it is the honest answer to
  "you have not told me which checkout speaks for this project" and is visible
  as soon as anyone looks.
  """
  @spec vantage(Scope.t()) :: Ecto.UUID.t() | nil
  def vantage(%Scope{active_working_copy_id: working_copy_id}) when is_binary(working_copy_id),
    do: working_copy_id

  def vantage(%Scope{active_project: %{default_working_copy_id: id}}) when is_binary(id), do: id

  def vantage(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Repo.one(
      from p in CodeMySpec.Projects.Project,
        where: p.id == ^project_id,
        select: p.default_working_copy_id
    )
  end

  def vantage(%Scope{}), do: nil

  @doc """
  Which requirements a file bears on.

  The question the blob could not answer, and the reason the graph became rows:
  a `bytea` addressed by one hash has no way to say which of its 5,000 nodes a
  changed file touches, so any change meant discarding the whole payload.

  A file records its owner — `component_id` or `story_id` — and so does a
  requirement, so this is one join. It returns rows rather than rehydrated
  nodes: the caller asking "what does this file affect" wants the set, and
  rehydration costs a definition lookup per node for fields it did not ask for.

  A file owned by nothing — unclassified, or project-level — bears on nothing,
  which is the honest answer rather than "every project requirement".
  """
  @spec for_file(Scope.t(), String.t()) :: [Node.t()]
  def for_file(%Scope{active_project_id: project_id}, path) do
    File
    |> where([f], f.project_id == ^project_id and f.path == ^path)
    |> select([f], {f.component_id, f.story_id})
    |> Repo.one()
    |> case do
      nil -> []
      {nil, nil} -> []
      {component_id, story_id} -> nodes_owned_by(component_id, story_id)
    end
  end

  # One clause per owner rather than an `or` across both. Ecto refuses
  # `field == ^nil` outright — it would mean `= NULL`, never true — and a file
  # has exactly one owner, so the shape of the data is two clauses.
  defp nodes_owned_by(component_id, nil) do
    Node |> where([n], n.component_id == ^component_id) |> Repo.all()
  end

  defp nodes_owned_by(nil, story_id) do
    Node |> where([n], n.story_id == ^story_id) |> Repo.all()
  end

  # A file claimed by both would be a sync bug, and answering with the union
  # would hide it. Neither is reachable through `for_file/2`, which returns
  # early on `{nil, nil}`.
  defp nodes_owned_by(component_id, story_id) do
    Node
    |> where([n], n.component_id == ^component_id or n.story_id == ^story_id)
    |> Repo.all()
  end

  # Only rows belonging to entities this project currently has. A component
  # deleted without its rows going with it would otherwise reappear as a node,
  # and `on_delete: :delete_all` covers the referential half but not a row whose
  # component id was nulled.
  defp project_rows(project_id, working_copy_id, ctx) do
    component_ids = Enum.map(ctx.components, & &1.id)
    story_ids = Enum.map(ctx.stories, & &1.id)

    Node
    |> where(
      [n],
      n.component_id in ^component_ids or n.story_id in ^story_ids or
        n.project_id == ^project_id
    )
    |> where(^copy_filter(working_copy_id))
    |> Repo.all()
  end

  # `is_nil` rather than `== nil`. `= NULL` is never true in SQL, so a project
  # with no default working copy would match no row and read as a graph with no
  # nodes — "you have not chosen a vantage point" arriving as "this project has
  # no requirements".
  defp copy_filter(nil), do: dynamic([n], is_nil(n.working_copy_id))
  defp copy_filter(id), do: dynamic([n], n.working_copy_id == ^id)

  defp rehydrate(row, ctx) do
    with {:ok, entity_type, entity} <- entity_for(row, ctx),
         %{} = definition <- definition_for(entity, row.name) do
      %Requirement{
        entity_type: entity_type,
        entity_id: entity_id(row, entity_type),
        entity_name: entity_name(entity),
        name: row.name,
        description: definition.description,
        satisfied: row.satisfied,
        satisfied_by: definition.satisfied_by,
        scope: definition.scope || :local,
        execution_type: definition.execution_type || :main_agent,
        validation_type: definition.validation_type || :automatic,
        prerequisites: definition.prerequisites || [],
        orchestrated_by: definition.orchestrated_by,
        render_command_always?: definition.render_command_always? || false,
        role: definition.role,
        details: row.details || %{}
      }
    else
      _ -> nil
    end
  end

  defp entity_for(%Node{component_id: id}, ctx) when not is_nil(id) do
    case Map.get(ctx.components_by_id, id) do
      nil -> :error
      component -> {:ok, "component", component}
    end
  end

  defp entity_for(%Node{story_id: id}, ctx) when not is_nil(id) do
    case Enum.find(ctx.stories, &(&1.id == id)) do
      nil -> :error
      story -> {:ok, "story", story}
    end
  end

  defp entity_for(%Node{project_id: id}, _ctx) when not is_nil(id),
    do: {:ok, "project", %CodeMySpec.Projects.Project{id: id}}

  defp entity_for(_row, _ctx), do: :error

  defp definition_for(entity, name) do
    entity
    |> Registry.get_requirements()
    |> Enum.find(&(&1.name == name))
  end

  defp entity_id(row, "component"), do: row.component_id
  defp entity_id(row, "story"), do: row.story_id
  defp entity_id(row, "project"), do: row.project_id

  defp entity_name(%{title: title}) when is_binary(title), do: title
  defp entity_name(%{module_name: name}) when is_binary(name), do: name
  defp entity_name(%{name: name}) when is_binary(name), do: name
  defp entity_name(_entity), do: nil

  # An edge is only in the graph if both its nodes rehydrated. One that lost an
  # end is an edge to a node the definitions no longer describe, and keeping it
  # would gate a node on something unreachable.
  defp edges_for(rows, by_id, ctx) do
    keys = Map.new(rows, &{&1.id, node_key(&1, ctx)})
    ids = Map.keys(by_id)

    Edge
    |> where([e], e.from_requirement_id in ^ids and e.to_requirement_id in ^ids)
    |> Repo.all()
    |> Enum.flat_map(fn edge ->
      case {Map.get(keys, edge.from_requirement_id), Map.get(keys, edge.to_requirement_id)} do
        {nil, _} -> []
        {_, nil} -> []
        {from, to} -> [%{from: from, to: to}]
      end
    end)
  end

  defp node_key(row, ctx) do
    case entity_for(row, ctx) do
      {:ok, entity_type, _entity} -> {entity_type, entity_id(row, entity_type), row.name}
      :error -> nil
    end
  end
end
