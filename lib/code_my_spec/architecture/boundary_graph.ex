defmodule CodeMySpec.Architecture.BoundaryGraph do
  @moduledoc """
  The architecture the compiler enforces: one node per `use Boundary` module,
  an edge wherever code crosses from one to another.

  Nodes come from the declarations the scan recorded
  (`Files.boundary_declarations/1`); edges from the component dependencies code
  shows (`in_code`), each rolled up to the boundary that owns its two modules
  and weighted by how many it rolls up. A module belongs to the boundary it
  is classified to, else the longest boundary name it sits under.

  Laid out top to bottom by depth — a boundary sits one layer below the
  deepest boundary that calls it — so the longest chain is the number of
  layers. A cycle is a strongly connected group of boundaries; its members
  share a layer and its edges are flagged.
  """

  alias CodeMySpec.Components
  alias CodeMySpec.Files
  alias CodeMySpec.Users.Scope

  @layer_gap 220
  @column_gap 260
  @node_color "#64748b"
  @cycle_color "#ef4444"

  @type t :: %{
          nodes: [map()],
          edges: [map()],
          layout: String.t(),
          summary: map()
        }

  @spec build(Scope.t()) :: t()
  def build(%Scope{} = scope) do
    declarations = Files.boundary_declarations(scope)
    roots = for d <- declarations, is_nil(d["classify_to"]), into: MapSet.new(), do: d["module"]

    classified =
      for d <- declarations, d["classify_to"], into: %{}, do: {d["module"], d["classify_to"]}

    modules = Map.new(Components.list_components(scope), &{&1.id, &1.module_name})
    owner = owner_fun(roots, classified)

    {weights, unowned} =
      scope
      |> Components.list_dependencies()
      |> Enum.filter(& &1.in_code)
      |> Enum.reduce({%{}, MapSet.new()}, fn dep, {weights, unowned} ->
        source = Map.get(modules, dep.source_component_id)
        target = Map.get(modules, dep.target_component_id)
        roll_up(owner.(source), owner.(target), source, target, weights, unowned)
      end)

    sizes = modules |> Map.values() |> Enum.map(owner) |> Enum.frequencies()
    endpoints = for {{from, to}, _} <- weights, node <- [from, to], into: MapSet.new(), do: node
    graph = %{nodes: roots |> MapSet.union(endpoints) |> MapSet.to_list(), edges: weights}
    components = strongly_connected(graph)
    cyclic = for c <- components, length(c) > 1, into: MapSet.new(), do: MapSet.new(c)
    group_of = for c <- components, m <- c, into: %{}, do: {m, MapSet.new(c)}
    layers = layers(graph, group_of)
    longest = longest_chain(graph, layers, group_of)

    %{
      nodes: nodes(graph.nodes, layers, sizes, group_of, cyclic),
      edges: edges(weights, group_of, cyclic),
      layout: "preset",
      summary: %{
        boundaries: length(graph.nodes),
        edges: map_size(weights),
        cycles: cyclic |> Enum.map(&(&1 |> Enum.sort() |> Enum.map(fn m -> short(m) end))),
        depth: max(length(longest) - 1, 0),
        longest_chain: Enum.map(longest, &short/1),
        unowned_modules: MapSet.size(unowned),
        declarations_recorded: declarations != []
      }
    }
  end

  # The boundary a module belongs to: its classification, itself, or the
  # longest boundary name it sits under.
  defp owner_fun(roots, classified) do
    ordered = roots |> Enum.sort_by(&(-String.length(&1)))

    fn
      nil ->
        nil

      module ->
        Map.get(classified, module) ||
          Enum.find(ordered, &(module == &1 or String.starts_with?(module, &1 <> ".")))
    end
  end

  defp roll_up(nil, _, source, _, weights, unowned), do: {weights, mark(unowned, source)}
  defp roll_up(_, nil, _, target, weights, unowned), do: {weights, mark(unowned, target)}
  defp roll_up(same, same, _, _, weights, unowned), do: {weights, unowned}

  defp roll_up(from, to, _, _, weights, unowned),
    do: {Map.update(weights, {from, to}, 1, &(&1 + 1)), unowned}

  defp mark(set, nil), do: set
  defp mark(set, module), do: MapSet.put(set, module)

  # Tarjan's algorithm over the boundary graph.
  defp strongly_connected(%{nodes: nodes, edges: weights}) do
    adjacency = adjacency(weights)

    initial = %{index: 0, indices: %{}, low: %{}, stack: [], on_stack: MapSet.new(), out: []}

    nodes
    |> Enum.sort()
    |> Enum.reduce(initial, fn node, state ->
      if Map.has_key?(state.indices, node), do: state, else: connect(node, adjacency, state)
    end)
    |> Map.fetch!(:out)
  end

  defp connect(node, adjacency, state) do
    state = %{
      state
      | index: state.index + 1,
        indices: Map.put(state.indices, node, state.index),
        low: Map.put(state.low, node, state.index),
        stack: [node | state.stack],
        on_stack: MapSet.put(state.on_stack, node)
    }

    state =
      adjacency
      |> Map.get(node, [])
      |> Enum.reduce(state, fn next, state ->
        cond do
          not Map.has_key?(state.indices, next) ->
            state = connect(next, adjacency, state)
            %{state | low: Map.update!(state.low, node, &min(&1, state.low[next]))}

          MapSet.member?(state.on_stack, next) ->
            %{state | low: Map.update!(state.low, node, &min(&1, state.indices[next]))}

          true ->
            state
        end
      end)

    if state.low[node] == state.indices[node], do: pop_component(node, state), else: state
  end

  defp pop_component(node, state) do
    {members, [^node | rest]} = Enum.split_while(state.stack, &(&1 != node))
    component = [node | members]

    %{
      state
      | stack: rest,
        on_stack: Enum.reduce(component, state.on_stack, &MapSet.delete(&2, &1)),
        out: [component | state.out]
    }
  end

  defp adjacency(weights) do
    Enum.reduce(weights, %{}, fn {{from, to}, _}, acc ->
      Map.update(acc, from, [to], &[to | &1])
    end)
  end

  # Longest path from a source to each group, over the graph with each cycle
  # collapsed to one group: a boundary sits below everything that calls it.
  defp layers(%{nodes: nodes, edges: weights}, group_of) do
    group_edges =
      for {{from, to}, _} <- weights,
          group_of[from] != group_of[to],
          uniq: true,
          do: {group_of[from], group_of[to]}

    groups = nodes |> Enum.map(&group_of[&1]) |> Enum.uniq()
    incoming = Enum.group_by(group_edges, &elem(&1, 1), &elem(&1, 0))

    {depths, _} =
      Enum.reduce(groups, {%{}, MapSet.new()}, fn group, acc -> depth(group, incoming, acc) end)

    for node <- nodes, into: %{}, do: {node, Map.fetch!(depths, group_of[node])}
  end

  defp depth(group, _incoming, {depths, _visiting} = acc) when is_map_key(depths, group), do: acc

  defp depth(group, incoming, {depths, visiting}) do
    callers = Map.get(incoming, group, [])

    {depths, visiting} =
      Enum.reduce(callers, {depths, MapSet.put(visiting, group)}, &depth(&1, incoming, &2))

    value =
      if callers == [], do: 0, else: 1 + Enum.max(Enum.map(callers, &Map.fetch!(depths, &1)))

    {Map.put(depths, group, value), visiting}
  end

  # One deepest chain, walked back up from the deepest boundary through a
  # caller one layer above at each step.
  defp longest_chain(%{nodes: []}, _layers, _group_of), do: []

  defp longest_chain(%{edges: weights}, layers, _group_of) when map_size(layers) > 0 do
    callers = Enum.group_by(Map.keys(weights), &elem(&1, 1), &elem(&1, 0))
    {deepest, _} = Enum.max_by(layers, fn {node, layer} -> {layer, node} end)
    walk_up(deepest, layers, callers, [deepest])
  end

  defp longest_chain(_, _, _), do: []

  defp walk_up(node, layers, callers, chain) do
    above =
      callers
      |> Map.get(node, [])
      |> Enum.filter(&(layers[&1] == layers[node] - 1))
      |> Enum.sort()
      |> List.first()

    if above, do: walk_up(above, layers, callers, [above | chain]), else: chain
  end

  defp nodes(names, layers, sizes, group_of, cyclic) do
    names
    |> Enum.group_by(&layers[&1])
    |> Enum.flat_map(fn {layer, members} ->
      members = Enum.sort(members)
      offset = (length(members) - 1) * @column_gap / 2

      members
      |> Enum.with_index()
      |> Enum.map(fn {name, column} ->
        in_cycle? = MapSet.member?(cyclic, group_of[name])

        %{
          key: name,
          attributes: %{
            label: short(name),
            x: column * @column_gap - offset,
            y: -layer * @layer_gap,
            size: 6 + :math.sqrt(Map.get(sizes, name, 1)),
            color: if(in_cycle?, do: @cycle_color, else: @node_color),
            type: "circle",
            layer: layer,
            modules: Map.get(sizes, name, 0),
            in_cycle: in_cycle?
          }
        }
      end)
    end)
  end

  defp edges(weights, group_of, cyclic) do
    for {{from, to}, weight} <- weights do
      cycle? = group_of[from] == group_of[to] and MapSet.member?(cyclic, group_of[from])

      %{
        key: "#{from}->#{to}",
        source: from,
        target: to,
        attributes: %{
          size: 1 + :math.log2(weight),
          weight: weight,
          cycle: cycle?,
          label: "#{weight}"
        }
      }
    end
  end

  defp short("CodeMySpec." <> rest), do: rest
  defp short(name), do: name
end
