defmodule CodeMySpec.Requirements.Projection do
  @moduledoc """
  Reads the requirement graph back out of rows.

  A row holds identity and verdict — `satisfied`, `details`, and which entity
  it belongs to. Everything else on a node is rehydrated from the
  `RequirementDefinition` by name (`scope`, `execution_type`,
  `validation_type`, `orchestrated_by`, `role`, `satisfied_by`,
  `render_command_always?`, `prerequisites`) or from the entity
  (`entity_name`, the orchestration parent), so a definition change needs no
  backfill.

  A row whose `name` matches no definition for its entity is dropped, not
  guessed at: the definitions moved and the node is no longer in the graph.
  """

  import Ecto.Query

  alias CodeMySpec.Files.File
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Edge, Node, Registry, Requirement}
  alias CodeMySpec.Users.Scope

  @doc """
  Every vantage this project already has rows in, `nil` among them.

  What the writer must keep current: rows are keyed per working copy, so one
  projector maintains every vantage it has rows in, not only the one that
  started it.

  `nil` is always included: every reader that is not an agent reads it.
  Vantages with no rows are not invented here; a reader that wants one asks
  for it by settling. Asked of project-owned rows, which every seeded vantage
  has.
  """
  @spec vantages(Scope.t()) :: [Ecto.UUID.t() | nil]
  def vantages(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    stored =
      Node
      |> where([n], n.project_id == ^project_id)
      |> distinct(true)
      |> select([n], n.working_copy_id)
      |> Repo.all()

    live_vantages(scope, stored)
  end

  def vantages(%Scope{}), do: [nil]

  @doc """
  The vantages worth computing, out of `nil`, the stored ones, and any a reader
  has asked for.

  Filters to checkouts that still exist: a row's `working_copy_id` references
  `working_copies`, so writing for a deleted checkout (named by a reader before
  the offboard) would fail every drain after it.
  """
  @spec live_vantages(Scope.t(), Enumerable.t()) :: [Ecto.UUID.t() | nil]
  def live_vantages(%Scope{active_project_id: project_id}, candidates)
      when is_binary(project_id) do
    candidates
    |> Enum.uniq()
    |> Enum.filter(&live_copy?(project_id, &1))
    |> then(&Enum.uniq([nil | &1]))
  end

  def live_vantages(%Scope{}, _candidates), do: [nil]

  defp live_copy?(_project_id, nil), do: true

  defp live_copy?(project_id, working_copy_id) do
    Repo.exists?(
      from(c in "working_copies",
        where:
          c.id == type(^working_copy_id, :binary_id) and
            c.project_id == type(^project_id, :binary_id)
      )
    )
  end

  @doc """
  The graph as `{nodes, edges}`, in the same shape `compute_graph/1` returns.

  ## Options

    * `:source` — `{nodes_schema, edges_schema}` to read instead of the
      default `{Node, Edge}`. No caller in `lib` passes it.
  """
  @spec load(Scope.t(), map(), keyword()) :: {[Requirement.t()], [map()]}
  def load(%Scope{active_project_id: project_id} = scope, ctx, opts \\ []) do
    {node_source, edge_source} = Keyword.get(opts, :source, {Node, Edge})

    rows = project_rows(node_source, project_id, vantage(scope), ctx)
    nodes = rows |> Enum.map(&rehydrate(&1, ctx)) |> Enum.reject(&is_nil/1)

    by_id = Map.new(rows, &{&1.id, &1})
    {nodes, edges_for(edge_source, rows, by_id, ctx)}
  end

  @doc """
  The rows of `stories` named `names`, each read at its own placement copy.

  For a reader whose role sees every story wherever it is placed (product). A
  placed story's nodes exist only at the copy it is reserved for, so that
  copy's verdict is the one there is. Edges are those between the rows read,
  which keeps each story's own chain; edges from other entities are left out.

  Every story must carry its `working_copy_id`.
  """
  @spec placed([map()], [String.t()]) :: {[Requirement.t()], [map()]}
  def placed([], _names), do: {[], []}

  def placed(stories, names) do
    copy_of = Map.new(stories, &{&1.id, &1.working_copy_id})
    copies = copy_of |> Map.values() |> Enum.uniq()

    rows =
      Node
      |> where([n], n.story_id in ^Map.keys(copy_of) and n.working_copy_id in ^copies)
      |> where([n], n.name in ^names)
      |> Repo.all()
      |> Enum.filter(&(Map.get(copy_of, &1.story_id) == &1.working_copy_id))

    ctx = %{stories: stories, components_by_id: %{}}
    nodes = rows |> Enum.map(&rehydrate(&1, ctx)) |> Enum.reject(&is_nil/1)
    {nodes, edges_for(Edge, rows, Map.new(rows, &{&1.id, &1}), ctx)}
  end

  @doc """
  Whose view of the project this read is.

  Every verdict is a statement about what one checkout could see, so a read
  names one. An agent reads as its own checkout: it must not be told a spec
  exists because another worktree has one.

  A reader that names no checkout reads the `nil` row-space. Which checkout's
  files that row-space describes is `Preloader.files_vantage/1`'s question;
  this one is whose answer it is, and it does not resolve.
  See knowledge/requirements_graph, "Vantages".
  """
  @spec vantage(Scope.t()) :: Ecto.UUID.t() | nil
  def vantage(%Scope{active_working_copy_id: working_copy_id}) when is_binary(working_copy_id),
    do: working_copy_id

  # Not the default checkout's id: storing a blended answer under a real
  # checkout's identity let a narrower writer overwrite it.
  def vantage(%Scope{}), do: nil

  @doc """
  Which requirements a file bears on.

  A file and a requirement both record their owner (`component_id` or
  `story_id`), so this is one join. Returns rows, not rehydrated nodes. A file
  owned by nothing bears on nothing.
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

  # One clause per owner: Ecto refuses `field == ^nil`, and a file has one owner.
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

  # Only rows of entities the context still has, so a row whose entity is gone
  # never reappears as a node.
  defp project_rows(source, project_id, working_copy_id, ctx) do
    component_ids = Enum.map(ctx.components, & &1.id)
    story_ids = Enum.map(ctx.stories, & &1.id)

    issue_ids =
      ctx
      |> Map.get(:story_issues, [])
      |> Enum.filter(&(&1.story_id in story_ids))
      |> Enum.map(& &1.id)

    source
    |> where(
      [n],
      n.component_id in ^component_ids or n.story_id in ^story_ids or n.issue_id in ^issue_ids or
        n.project_id == ^project_id
    )
    |> where(^copy_filter(working_copy_id))
    |> Repo.all()
  end

  # `is_nil`, never `== nil`: `= NULL` matches no row and would read as a graph
  # with no requirements.
  defp copy_filter(nil), do: dynamic([n], is_nil(n.working_copy_id))
  defp copy_filter(id), do: dynamic([n], n.working_copy_id == ^id)

  defp rehydrate(row, ctx) do
    with {:ok, entity_type, entity} <- entity_for(row, ctx),
         %{} = definition <- definition_for(row, entity, row.name) do
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
        details: row.details || %{},
        checked_at: row.checked_at,
        inputs_fingerprint: row.inputs_fingerprint
      }
      |> with_parent(entity_type, entity, definition, ctx)
    else
      _ -> nil
    end
  end

  # Who orchestrates this node, derived from the entity, never stored. Same rule
  # as a computed node (`Requirement.orchestration_parent/3`): a child takes its
  # explicit parent; an orchestrated parent- or self-scope node self-parents, so
  # it groups under its own context. A nil parent renders as `## unknown`.
  defp with_parent(%Requirement{} = req, "component", component, definition, ctx) do
    parent =
      if definition.node_scope == :child,
        do: Map.get(ctx.components_by_id, Map.get(component, :parent_component_id))

    {parent_id, parent_name} = Requirement.orchestration_parent(definition, component, parent)
    %{req | parent_entity_id: parent_id, parent_entity_name: parent_name}
  end

  defp with_parent(req, "issue", issue, _definition, ctx) do
    story = Enum.find(ctx.stories, &(&1.id == issue.story_id))
    %{req | parent_entity_id: issue.story_id, parent_entity_name: story && story.title}
  end

  defp with_parent(req, "story", story, _definition, _ctx),
    do: %{req | parent_entity_id: story.project_id}

  defp with_parent(req, _type, _entity, _definition, _ctx), do: req

  defp entity_for(%Node{component_id: id}, ctx) when not is_nil(id) do
    case Map.get(ctx.components_by_id, id) do
      nil -> :error
      component -> {:ok, "component", component}
    end
  end

  defp entity_for(%Node{issue_id: id}, ctx) when not is_nil(id) do
    case Enum.find(Map.get(ctx, :story_issues, []), &(&1.id == id)) do
      nil -> :error
      issue -> {:ok, "issue", issue}
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

  # The row says which definition produced it, because the name alone does not.
  #
  # `implementation_file` exists as a child definition on a parent template
  # and as a self definition on a leaf. The parent's definition carries the
  # orchestration group, which must survive persistence and rehydration.
  #
  # `nil` columns mean a row written before they existed; the entity's own type
  # stands in until the row is next rewritten.
  defp definition_for(row, entity, name) do
    stored_definition(row, name) || own_definition(entity, name)
  end

  defp stored_definition(%Node{owner_component_type: type, node_scope: scope}, name)
       when is_binary(type) and is_binary(scope) do
    type
    |> Registry.get_requirements_for_type()
    |> Enum.find(&(&1.name == name and to_string(&1.node_scope) == scope))
  end

  defp stored_definition(_row, _name), do: nil

  defp own_definition(entity, name) do
    entity
    |> Registry.get_requirements()
    |> Enum.find(&(&1.name == name))
  end

  defp entity_id(row, "component"), do: row.component_id
  defp entity_id(row, "issue"), do: row.issue_id
  defp entity_id(row, "story"), do: row.story_id
  defp entity_id(row, "project"), do: row.project_id

  defp entity_name(%{title: title}) when is_binary(title), do: title
  defp entity_name(%{module_name: name}) when is_binary(name), do: name
  defp entity_name(%{name: name}) when is_binary(name), do: name
  defp entity_name(_entity), do: nil

  # An edge is only in the graph if both its nodes rehydrated; one that lost an
  # end would gate a node on something unreachable.
  defp edges_for(source, rows, by_id, ctx) do
    keys = Map.new(rows, &{&1.id, node_key(&1, ctx)})
    ids = Map.keys(by_id)

    source
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
