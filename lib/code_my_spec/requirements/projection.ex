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

  alias CodeMySpec.Requirements.{Edges, GraphStore, Node, Registry, Requirement, Topology}
  alias CodeMySpec.Users.Scope

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
  Rows as nodes: identity and verdict from the row, everything else from its
  definition and entity. A row whose entity `ctx` lacks, or whose name matches
  no definition, is dropped. Entities indexed by id once, and each definition
  set built once per read: a read has thousands of rows.
  """
  @spec rehydrate_all([Node.t()], map()) :: [Requirement.t()]
  def rehydrate_all(rows, ctx) do
    ix =
      Map.merge(ctx, %{
        stories_by_id: Map.new(ctx.stories, &{&1.id, &1}),
        issues_by_id: ctx |> Map.get(:story_issues, []) |> Map.new(&{&1.id, &1})
      })

    {nodes, _definitions} = Enum.map_reduce(rows, %{}, &rehydrate(&1, ix, &2))
    Enum.reject(nodes, &is_nil/1)
  end

  defp rehydrate(row, ix, definitions) do
    with {:ok, entity_type, entity} <- entity_for(row, ix),
         {%{} = definition, definitions} <- definition_for(row, entity, definitions) do
      node =
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
        |> with_parent(entity_type, entity, definition, ix)

      {node, definitions}
    else
      :error -> {nil, definitions}
      {nil, definitions} -> {nil, definitions}
    end
  end

  # Who orchestrates this node, derived from the entity, never stored. Same rule
  # as a computed node (`Requirement.orchestration_parent/3`): a child takes its
  # explicit parent; an orchestrated parent- or self-scope node self-parents, so
  # it groups under its own context. A nil parent renders as `## unknown`.
  defp with_parent(%Requirement{} = req, "component", component, definition, ix) do
    parent =
      if definition.node_scope == :child,
        do: Map.get(ix.components_by_id, Map.get(component, :parent_component_id))

    {parent_id, parent_name} = Requirement.orchestration_parent(definition, component, parent)
    %{req | parent_entity_id: parent_id, parent_entity_name: parent_name}
  end

  defp with_parent(req, "issue", issue, _definition, ix) do
    story = Map.get(ix.stories_by_id, issue.story_id)
    %{req | parent_entity_id: issue.story_id, parent_entity_name: story && story.title}
  end

  defp with_parent(req, "story", story, _definition, _ix),
    do: %{req | parent_entity_id: story.project_id}

  defp with_parent(req, _type, _entity, _definition, _ix), do: req

  defp entity_for(%Node{component_id: id}, ix) when not is_nil(id),
    do: found("component", Map.get(ix.components_by_id, id))

  defp entity_for(%Node{issue_id: id}, ix) when not is_nil(id),
    do: found("issue", Map.get(ix.issues_by_id, id))

  defp entity_for(%Node{story_id: id}, ix) when not is_nil(id),
    do: found("story", Map.get(ix.stories_by_id, id))

  defp entity_for(%Node{project_id: id}, _ix) when not is_nil(id),
    do: {:ok, "project", %CodeMySpec.Projects.Project{id: id}}

  defp entity_for(_row, _ix), do: :error

  defp found(_entity_type, nil), do: :error
  defp found(entity_type, entity), do: {:ok, entity_type, entity}

  # The row says which definition produced it, because the name alone does not.
  #
  # `implementation_file` exists as a child definition on a parent template
  # and as a self definition on a leaf. The parent's definition carries the
  # orchestration group, which must survive persistence and rehydration.
  #
  # `nil` columns mean a row written before they existed; the entity's own type
  # stands in until the row is next rewritten.
  defp definition_for(%Node{owner_component_type: type, node_scope: scope} = row, entity, defs)
       when is_binary(type) and is_binary(scope) do
    {set, defs} =
      definitions(defs, {:type, type}, fn -> Registry.get_requirements_for_type(type) end)

    case Enum.find(set, &(&1.name == row.name and to_string(&1.node_scope) == scope)) do
      nil -> own_definition(row, entity, defs)
      definition -> {definition, defs}
    end
  end

  defp definition_for(row, entity, defs), do: own_definition(row, entity, defs)

  defp own_definition(row, entity, defs) do
    {set, defs} = definitions(defs, own_key(entity), fn -> Registry.get_requirements(entity) end)
    {Enum.find(set, &(&1.name == row.name)), defs}
  end

  defp own_key(%{__struct__: struct, type: type}), do: {struct, type}
  defp own_key(%{__struct__: struct}), do: struct

  defp definitions(defs, key, build) do
    case defs do
      %{^key => set} ->
        {set, defs}

      _ ->
        set = build.()
        {set, Map.put(defs, key, set)}
    end
  end

  defp entity_id(row, "component"), do: row.component_id
  defp entity_id(row, "issue"), do: row.issue_id
  defp entity_id(row, "story"), do: row.story_id
  defp entity_id(row, "project"), do: row.project_id

  defp entity_name(%{title: title}) when is_binary(title), do: title
  defp entity_name(%{module_name: name}) when is_binary(name), do: name
  defp entity_name(%{name: name}) when is_binary(name), do: name
  defp entity_name(_entity), do: nil

  @doc """
  The project's edges among `nodes`. An edge is only in the graph if both its
  nodes rehydrated; one that lost an end would gate a node on something
  unreachable.
  """
  @spec edges_for(Ecto.UUID.t(), [Requirement.t()]) :: [map()]
  def edges_for(project_id, nodes),
    do: project_id |> GraphStore.edges() |> Edges.among(MapSet.new(nodes, &Topology.node_key/1))
end
