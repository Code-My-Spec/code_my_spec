defmodule CodeMySpecWeb.WorkingCopyLive.StoryGraph do
  @moduledoc "Read-only presentation of one story and its upstream component requirements."

  alias LiveFlow.{Edge, Handle, Node, State}

  def build(graph, agent_work \\ nil, teams \\ []) do
    actionable_nodes =
      if is_nil(agent_work),
        do: graph.actionable,
        else: Enum.flat_map(agent_work, fn {_agent, work} -> work.actionable end)

    next_agents =
      Enum.reduce(agent_work || [], %{}, fn {agent, work}, acc ->
        case List.first(work.actionable) do
          nil -> acc
          node -> Map.update(acc, key(node), [agent], &(&1 ++ [agent]))
        end
      end)

    by_key = Map.new(graph.nodes, &{key(&1), &1})
    included = MapSet.new(graph.nodes, &key/1)
    roots = graph.story_keys
    actionable = MapSet.new(actionable_nodes, &key/1)

    nodes =
      included
      |> Enum.filter(&Map.has_key?(by_key, &1))
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.map(fn {key, index} ->
        requirement = Map.fetch!(by_key, key)

        status =
          cond do
            requirement.satisfied -> "Satisfied"
            MapSet.member?(actionable, key) -> "Actionable"
            true -> "Blocked"
          end

        Node.new(
          id(key),
          %{x: 0, y: index * 130},
          %{
            requirement: requirement,
            next_agents: Map.get(next_agents, key, []),
            warnings: warnings(requirement, teams),
            label: humanize(requirement.name),
            status: status,
            boundary: not MapSet.member?(roots, key)
          },
          type: :requirement,
          draggable: false,
          connectable: false,
          deletable: false,
          style: %{width: "260px"},
          handles: [
            Handle.new(:target, :left, connectable: false),
            Handle.new(:source, :right, connectable: false)
          ]
        )
        |> Map.merge(%{width: 260, height: 112})
      end)

    edges =
      graph.edges
      |> Enum.filter(&(MapSet.member?(included, &1.from) and MapSet.member?(included, &1.to)))
      |> Enum.uniq_by(&{&1.from, &1.to})
      |> Enum.map(fn edge ->
        Edge.new("#{id(edge.from)}--#{id(edge.to)}", id(edge.from), id(edge.to),
          type: :smoothstep,
          selectable: false,
          deletable: false
        )
      end)

    State.new(nodes: nodes, edges: edges) |> group_components(graph.components ++ graph.owners)
  end

  def filter_teams(teams, nil), do: teams

  def filter_teams(teams, selected) do
    ids = MapSet.new(selected.data.warnings, & &1.id)

    teams
    |> Enum.map(fn team ->
      %{
        team
        | questions: Enum.filter(team.questions, &MapSet.member?(ids, &1.id)),
          tap_outs: Enum.filter(team.tap_outs, &MapSet.member?(ids, &1.id))
      }
    end)
    |> Enum.reject(&(&1.questions == [] and &1.tap_outs == []))
  end

  defp warnings(requirement, teams) do
    field =
      case requirement.entity_type do
        "story" -> :story_id
        "component" -> :component_id
        "project" -> :project_id
        "issue" -> :issue_id
        _ -> nil
      end

    Enum.flat_map(teams, fn team ->
      tasks =
        Enum.filter(team.agent.tasks || [], &task_for_requirement?(&1, field, requirement))

      ids = MapSet.new(tasks, & &1.id)

      Enum.filter(team.questions ++ team.tap_outs, fn request ->
        request.status == "pending" && not is_nil(request.task_id) &&
          MapSet.member?(ids, request.task_id)
      end)
    end)
  end

  defp task_for_requirement?(task, field, requirement) do
    field && task_name(requirement.entity_type, task.requirement_name) == requirement.name &&
      to_string(Map.get(task, field)) == to_string(requirement.entity_id)
  end

  defp group_components(flow, []), do: flow

  defp group_components(flow, components) do
    by_id = Map.new(components, &{&1.id, &1})

    owners =
      Map.new(flow.nodes, fn {id, node} ->
        case node.data.requirement do
          %{entity_type: "component", entity_id: component_id} ->
            owner = context_owner(component_id, by_id, MapSet.new()) || component_id
            {id, "context-#{owner}"}

          _ ->
            {id, id}
        end
      end)

    nodes =
      flow.nodes
      |> Map.values()
      |> Enum.group_by(&owners[&1.id])
      |> Map.new(&group_node(&1, by_id))

    edges =
      flow.edges
      |> Map.values()
      |> Enum.map(fn edge ->
        source = owners[edge.source]
        target = owners[edge.target]
        %{edge | id: "#{source}--#{target}", source: source, target: target}
      end)
      |> Enum.reject(&(&1.source == &1.target))
      |> Enum.uniq_by(& &1.id)

    %{flow | nodes: nodes, edges: Map.new(edges, &{&1.id, &1})}
  end

  defp group_node({id, members}, by_id) do
    first = hd(members)

    if first.data.requirement.entity_type == "component" do
      owner_id = String.replace_prefix(id, "context-", "")
      owner = by_id[owner_id]

      requirements =
        members
        |> Enum.map(& &1.data)
        |> Enum.sort_by(&{&1.requirement.entity_name || "", &1.requirement.name})

      counts = Enum.frequencies_by(requirements, & &1.status)

      status =
        cond do
          Map.get(counts, "Satisfied", 0) == length(requirements) -> "Satisfied"
          Map.get(counts, "Actionable", 0) > 0 -> "Actionable"
          true -> "Blocked"
        end

      data = %{
        label: (owner && owner.module_name) || first.data.requirement.entity_name || owner_id,
        status: status,
        counts: counts,
        warnings: requirements |> Enum.flat_map(& &1.warnings) |> Enum.uniq_by(& &1.id),
        next_agents: requirements |> Enum.flat_map(& &1.next_agents) |> Enum.uniq_by(& &1.id),
        requirements: requirements,
        boundary: Enum.all?(requirements, & &1.boundary)
      }

      {id, %{first | id: id, type: :context, data: data}}
    else
      {id, first}
    end
  end

  # Use recorded ownership, including nested children; never infer a context
  # from a module-name prefix. Unowned components stay visible on their own.
  defp context_owner(id, components, seen) do
    if MapSet.member?(seen, id) do
      nil
    else
      case components[id] do
        %{type: type} when type in ["context", "live_context"] ->
          id

        %{parent_component_id: parent} when not is_nil(parent) ->
          context_owner(parent, components, MapSet.put(seen, id))

        _ ->
          nil
      end
    end
  end

  def preserve_view(flow, nil), do: flow

  def preserve_view(flow, previous) do
    nodes =
      Map.new(flow.nodes, fn {id, node} ->
        case previous.nodes[id] do
          nil ->
            {id, node}

          old ->
            {id,
             %{
               node
               | position: old.position,
                 width: old.width,
                 height: old.height,
                 selected: old.selected
             }}
        end
      end)

    %{flow | nodes: nodes, viewport: previous.viewport}
  end

  defp key(node), do: {node.entity_type, node.entity_id, task_name(node.entity_type, node.name)}

  defp task_name("issue", "fix_issue"), do: "submitted"
  defp task_name("issue", name) when name in ["qa_complete", "promote_issue"], do: "completed"
  defp task_name(_type, name), do: name
  defp id({type, entity_id, name}), do: "#{type}-#{entity_id}-#{name}"
  defp humanize(name), do: name |> String.replace("_", " ") |> String.capitalize()
end
