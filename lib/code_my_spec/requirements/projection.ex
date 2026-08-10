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
  `orchestrated_by`, `subagent_role`, `satisfied_by`, `render_command_always?`,
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

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Edge, Node, Registry, Requirement}
  alias CodeMySpec.Users.Scope

  @doc """
  The graph as `{nodes, edges}`, in the same shape `compute_graph/1` returns.
  """
  @spec load(Scope.t(), map()) :: {[Requirement.t()], [map()]}
  def load(%Scope{active_project_id: project_id}, ctx) do
    rows = project_rows(project_id, ctx)
    nodes = rows |> Enum.map(&rehydrate(&1, ctx)) |> Enum.reject(&is_nil/1)

    by_id = Map.new(rows, &{&1.id, &1})
    {nodes, edges_for(rows, by_id, ctx)}
  end

  # Only rows belonging to entities this project currently has. A component
  # deleted without its rows going with it would otherwise reappear as a node,
  # and `on_delete: :delete_all` covers the referential half but not a row whose
  # component id was nulled.
  defp project_rows(project_id, ctx) do
    component_ids = Enum.map(ctx.components, & &1.id)
    story_ids = Enum.map(ctx.stories, & &1.id)

    Node
    |> where(
      [n],
      n.component_id in ^component_ids or n.story_id in ^story_ids or
        n.project_id == ^project_id
    )
    |> Repo.all()
  end

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
        subagent_role: definition.subagent_role,
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
