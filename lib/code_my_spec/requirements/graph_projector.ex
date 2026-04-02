defmodule CodeMySpec.Requirements.GraphProjector do
  @moduledoc """
  Projects the computed requirement graph into a JSON structure for sigma.js.

  Layout is horizontal layers:
  1. Project chain (vertical, centered)
  2. Stories as columns: component_linked + bdd_specs_exist
  3. Component zone: context summaries spread horizontally
  4. Stories resume: bdd_specs_passing + qa_complete
  5. Late project chain
  """

  alias CodeMySpec.Components
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Users.Scope

  @colors %{
    satisfied: "#60a5fa",
    actionable: "#4ade80",
    blocked: "#fbbf24"
  }

  @row_gap 500
  @story_col_gap 700
  @story_row_gap 350
  @comp_gap 500
  @comp_zone_height 800

  @context_types MapSet.new(["context", "live_context", "controller"])
  @pre_component_reqs ["component_linked", "bdd_specs_exist"]
  @post_component_reqs ["bdd_specs_passing", "qa_complete"]

  @spec project_graph(Scope.t()) :: map()
  def project_graph(%Scope{} = scope) do
    %{nodes: nodes, edges: edges} = Requirements.project_graph(scope)
    actionable = Requirements.next_actionable_project(scope)

    actionable_set =
      MapSet.new(actionable, fn n -> {n.entity_type, n.entity_id, n.name} end)

    components = Components.list_components_with_dependencies(scope)
    comp_map = Map.new(components, &{&1.id, &1})

    comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component"))
    comp_reqs_by_id = Enum.group_by(comp_nodes, & &1.entity_id)
    context_groups = build_context_groups(comp_reqs_by_id, components)
    comp_key_to_summary = build_key_mapping(context_groups, comp_reqs_by_id, comp_map)

    project_nodes = Enum.filter(nodes, &(&1.entity_type == "project"))
    story_nodes = Enum.filter(nodes, &(&1.entity_type == "story"))

    proj_order = definition_order()
    sorted_project = Enum.sort_by(project_nodes, fn n -> Map.get(proj_order, n.name, 999) end)

    fan_in_idx = Enum.find_index(sorted_project, &(&1.name == "qa_preflight")) || 0
    {early_project, late_project} = Enum.split(sorted_project, fan_in_idx)

    story_order = story_definition_order()
    stories_by_id = Enum.group_by(story_nodes, & &1.entity_id)
    sorted_stories =
      stories_by_id
      |> Enum.sort_by(fn {_id, [first | _]} -> first.entity_name end)
      |> Enum.with_index()

    story_count = length(sorted_stories)

    # --- Layer 1: Early project chain ---
    early_sigma =
      early_project
      |> Enum.with_index()
      |> Enum.map(fn {n, idx} ->
        mk_node(nkey(n), label(n), 0, -(idx * @row_gap), 18, cls(n, actionable_set),
          entity_type: "project", name: n.name)
      end)

    # --- Layer 2: Pre-component story reqs (all stories, same Y band) ---
    story_start_y = -(length(early_project) * @row_gap)

    pre_sigma =
      Enum.flat_map(sorted_stories, fn {{_id, reqs}, col_idx} ->
        sorted_reqs = Enum.sort_by(reqs, fn r -> Map.get(story_order, r.name, 999) end)
        x = (col_idx - (story_count - 1) / 2) * @story_col_gap
        pre = Enum.filter(sorted_reqs, &(&1.name in @pre_component_reqs))

        pre
        |> Enum.with_index()
        |> Enum.map(fn {req, idx} ->
          y = story_start_y - (idx * @story_row_gap)
          mk_node(nkey(req), story_label(req), x, y, 12, cls(req, actionable_set),
            entity_type: "story", entity_id: req.entity_id, name: req.name)
        end)
      end)

    # --- Layer 3: Component zone ---
    comp_zone_y = story_start_y - (length(@pre_component_reqs) * @story_row_gap) - @row_gap

    # Collect unique context summaries needed by stories
    needed_context_ids =
      sorted_stories
      |> Enum.flat_map(fn {{_id, reqs}, _} ->
        sorted_reqs = Enum.sort_by(reqs, fn r -> Map.get(story_order, r.name, 999) end)
        linked = Enum.find(sorted_reqs, &(&1.name == "component_linked"))
        surface_id = linked && linked.details[:component_id]

        if surface_id do
          surface = Map.get(comp_map, surface_id)
          deps = if surface, do: surface.dependencies || [], else: []
          dep_ctx_ids = deps |> Enum.filter(&(&1.type in @context_types)) |> Enum.map(& &1.id)
          [surface_id | dep_ctx_ids]
        else
          []
        end
      end)
      |> Enum.uniq()

    # Build summary nodes for components, spread horizontally
    comp_count = length(needed_context_ids)

    comp_sigma =
      needed_context_ids
      |> Enum.with_index()
      |> Enum.map(fn {comp_id, idx} ->
        x = (idx - (comp_count - 1) / 2) * @comp_gap
        reqs = Map.get(context_groups, comp_id, Map.get(comp_reqs_by_id, comp_id, []))
        sat = Enum.count(reqs, & &1.satisfied)
        total = length(reqs)
        comp = Map.get(comp_map, comp_id)
        name = if comp, do: short_module(comp.module_name), else: "Component"

        mk_node(summary_key(comp_id), "#{name} #{sat}/#{total}", x, comp_zone_y, 16,
          summary_status(reqs, actionable_set),
          entity_type: "component", entity_id: comp_id)
      end)

    # --- Layer 4: Post-component story reqs ---
    post_zone_y = comp_zone_y - @comp_zone_height

    post_sigma =
      Enum.flat_map(sorted_stories, fn {{_id, reqs}, col_idx} ->
        sorted_reqs = Enum.sort_by(reqs, fn r -> Map.get(story_order, r.name, 999) end)
        x = (col_idx - (story_count - 1) / 2) * @story_col_gap
        post = Enum.filter(sorted_reqs, &(&1.name in @post_component_reqs))

        post
        |> Enum.with_index()
        |> Enum.map(fn {req, idx} ->
          y = post_zone_y - (idx * @story_row_gap)
          mk_node(nkey(req), story_label(req), x, y, 12, cls(req, actionable_set),
            entity_type: "story", entity_id: req.entity_id, name: req.name)
        end)
      end)

    # --- Layer 5: Late project chain ---
    late_start_y = post_zone_y - (length(@post_component_reqs) * @story_row_gap) - @row_gap

    late_sigma =
      late_project
      |> Enum.with_index()
      |> Enum.map(fn {n, idx} ->
        mk_node(nkey(n), label(n), 0, late_start_y - (idx * @row_gap), 18, cls(n, actionable_set),
          entity_type: "project", name: n.name)
      end)

    all_sigma = early_sigma ++ pre_sigma ++ comp_sigma ++ post_sigma ++ late_sigma
    all_keys = MapSet.new(all_sigma, & &1.key)

    # Edges: rewrite component req keys to summary keys
    sigma_edges =
      edges
      |> Enum.map(fn e ->
        from = rewrite_key(e.from, comp_key_to_summary)
        to = rewrite_key(e.to, comp_key_to_summary)
        {from, to, e}
      end)
      |> Enum.filter(fn {f, t, _} -> MapSet.member?(all_keys, f) and MapSet.member?(all_keys, t) end)
      |> Enum.uniq_by(fn {f, t, _} -> {f, t} end)
      |> Enum.reject(fn {f, t, _} -> f == t end)
      |> Enum.map(fn {f, t, e} ->
        %{key: "#{f}->#{t}", source: f, target: t,
          attributes: %{size: 2, color: edge_color(e), type: "arrow"}}
      end)

    # Dependency edges between component summaries
    dep_edges = build_dependency_edges(comp_sigma, comp_map, all_keys)

    %{nodes: all_sigma, edges: sigma_edges ++ dep_edges}
  end

  @doc """
  Components-only graph: one summary node per bounded context with
  dependency edges between them.
  """
  @spec components_graph(Scope.t()) :: map()
  def components_graph(%Scope{} = scope) do
    %{nodes: nodes} = Requirements.project_graph(scope)
    actionable = Requirements.next_actionable_project(scope)

    actionable_set =
      MapSet.new(actionable, fn n -> {n.entity_type, n.entity_id, n.name} end)

    comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component"))
    comp_reqs_by_id = Enum.group_by(comp_nodes, & &1.entity_id)

    components = Components.list_components_with_dependencies(scope)

    context_ids =
      components
      |> Enum.filter(fn c -> c.type in @context_types end)
      |> MapSet.new(& &1.id)

    child_to_context =
      components
      |> Enum.filter(fn c -> c.parent_component_id && MapSet.member?(context_ids, c.parent_component_id) end)
      |> Map.new(fn c -> {c.id, c.parent_component_id} end)

    groups =
      components
      |> Enum.filter(fn c -> MapSet.member?(context_ids, c.id) end)
      |> Enum.map(fn ctx ->
        children = Enum.filter(components, &(&1.parent_component_id == ctx.id))
        own_reqs = Map.get(comp_reqs_by_id, ctx.id, [])
        child_reqs = Enum.flat_map(children, fn c -> Map.get(comp_reqs_by_id, c.id, []) end)
        {ctx.id, %{component: ctx, reqs: own_reqs ++ child_reqs}}
      end)

    standalone =
      components
      |> Enum.filter(fn c ->
        !MapSet.member?(context_ids, c.id) and !Map.has_key?(child_to_context, c.id)
      end)
      |> Enum.map(fn c ->
        {c.id, %{component: c, reqs: Map.get(comp_reqs_by_id, c.id, [])}}
      end)

    all_groups = (groups ++ standalone) |> Enum.sort_by(fn {_id, g} -> g.component.module_name end)
    count = length(all_groups)
    cols = max(ceil(:math.sqrt(count)), 1)

    sigma_nodes =
      all_groups
      |> Enum.with_index()
      |> Enum.map(fn {{comp_id, group}, idx} ->
        col = rem(idx, cols)
        row = div(idx, cols)
        x = (col - (cols - 1) / 2) * 600
        y = -(row * 500)

        reqs = group.reqs
        sat = Enum.count(reqs, & &1.satisfied)
        total = length(reqs)
        name = short_module(group.component.module_name)

        mk_node(summary_key(comp_id), "#{name} #{sat}/#{total}", x, y, 16,
          summary_status(reqs, actionable_set),
          entity_type: "component", entity_id: comp_id)
      end)

    all_keys = MapSet.new(sigma_nodes, & &1.key)

    dep_edges =
      all_groups
      |> Enum.flat_map(fn {_id, group} ->
        from_key = summary_key(group.component.id)
        deps = group.component.dependencies || []

        Enum.flat_map(deps, fn dep ->
          dep_ctx_id = Map.get(child_to_context, dep.id, dep.id)
          to_key = summary_key(dep_ctx_id)

          if to_key != from_key and MapSet.member?(all_keys, to_key) do
            [%{key: "dep_#{from_key}->#{to_key}", source: from_key, target: to_key,
              attributes: %{size: 2, color: "#6366f1", type: "arrow"}}]
          else
            []
          end
        end)
      end)
      |> Enum.uniq_by(& &1.key)

    %{nodes: sigma_nodes, edges: dep_edges}
  end

  # -- Context groups --

  defp build_context_groups(comp_reqs_by_id, components) do
    context_ids =
      components
      |> Enum.filter(fn c -> c.type in @context_types end)
      |> MapSet.new(& &1.id)

    Enum.reduce(components, %{}, fn comp, acc ->
      if MapSet.member?(context_ids, comp.id) do
        children = Enum.filter(components, &(&1.parent_component_id == comp.id))
        child_reqs = Enum.flat_map(children, fn c -> Map.get(comp_reqs_by_id, c.id, []) end)
        own_reqs = Map.get(comp_reqs_by_id, comp.id, [])
        Map.put(acc, comp.id, own_reqs ++ child_reqs)
      else
        acc
      end
    end)
  end

  defp build_key_mapping(context_groups, comp_reqs_by_id, comp_map) do
    ctx_mappings =
      Enum.flat_map(context_groups, fn {ctx_id, reqs} ->
        key = summary_key(ctx_id)
        Enum.map(reqs, fn r -> {{r.entity_type, r.entity_id, r.name}, key} end)
      end)

    standalone =
      comp_reqs_by_id
      |> Enum.flat_map(fn {comp_id, reqs} ->
        comp = Map.get(comp_map, comp_id)
        parent_id = comp && comp.parent_component_id

        in_context = Map.has_key?(context_groups, comp_id) or
                     (parent_id && Map.has_key?(context_groups, parent_id))

        if in_context do
          []
        else
          key = summary_key(comp_id)
          Enum.map(reqs, fn r -> {{r.entity_type, r.entity_id, r.name}, key} end)
        end
      end)

    Map.new(ctx_mappings ++ standalone)
  end

  defp build_dependency_edges(comp_sigma_nodes, comp_map, all_keys) do
    comp_sigma_nodes
    |> Enum.flat_map(fn node ->
      comp_id = node.attributes[:entity_id]
      comp = comp_id && Map.get(comp_map, comp_id)
      deps = (comp && comp.dependencies) || []

      Enum.flat_map(deps, fn dep ->
        dep_key = summary_key(dep.id)
        if dep_key != node.key and MapSet.member?(all_keys, dep_key) do
          [%{key: "dep_#{node.key}->#{dep_key}", source: node.key, target: dep_key,
            attributes: %{size: 1, color: "#6366f1", type: "arrow"}}]
        else
          []
        end
      end)
    end)
    |> Enum.uniq_by(& &1.key)
  end

  # -- Node builders --

  defp mk_node(key, label, x, y, size, status, extra) do
    %{
      key: key,
      attributes:
        Map.merge(
          %{label: label, x: x, y: y, size: size, color: color(status), type: "circle"},
          Map.new(extra)
        )
    }
  end

  defp summary_key(comp_id), do: "ctx_#{sanitize_id(comp_id)}"

  defp rewrite_key(key, mapping) do
    case Map.get(mapping, key) do
      nil -> key_to_string(key)
      summary -> summary
    end
  end

  defp nkey(n), do: key_to_string({n.entity_type, n.entity_id, n.name})
  defp key_to_string({type, id, name}), do: "#{type}_#{sanitize_id(id)}_#{name}"
  defp sanitize_id(id) when is_integer(id), do: "#{id}"
  defp sanitize_id(id) when is_binary(id), do: String.replace(id, "-", "")

  # -- Labels --

  defp label(n) do
    name = n.name |> String.replace("_", " ")
    if n.satisfied, do: "#{name} ✓", else: name
  end

  defp story_label(n) do
    title = short_title(n.entity_name)
    name = n.name |> String.replace("_", " ")
    if n.satisfied, do: "#{title}: #{name} ✓", else: "#{title}: #{name}"
  end

  defp comp_label(n) do
    mod = short_module(n.entity_name)
    name = n.name |> String.replace("_", " ")
    if n.satisfied, do: "#{mod}: #{name} ✓", else: "#{mod}: #{name}"
  end

  defp short_title(t), do: if(String.length(t) > 20, do: String.slice(t, 0, 20) <> "..", else: t)

  defp short_module(m) do
    parts = String.split(m, ".")
    if length(parts) <= 2, do: m, else: Enum.drop(parts, 1) |> Enum.join(".")
  end

  # -- Status --

  defp cls(%{satisfied: true}, _), do: :satisfied
  defp cls(n, actionable_set) do
    key = {n.entity_type, n.entity_id, n.name}
    if MapSet.member?(actionable_set, key), do: :actionable, else: :blocked
  end

  defp summary_status(reqs, actionable_set) do
    sat = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)
    cond do
      sat == total and total > 0 -> :satisfied
      Enum.any?(reqs, fn r -> MapSet.member?(actionable_set, {r.entity_type, r.entity_id, r.name}) end) -> :actionable
      true -> :blocked
    end
  end

  defp color(:satisfied), do: @colors.satisfied
  defp color(:actionable), do: @colors.actionable
  defp color(:blocked), do: @colors.blocked
  defp color(_), do: @colors.blocked

  defp edge_color(%{from: {ft, _, _}, to: {tt, _, _}}) when ft != tt, do: "#818cf8"
  defp edge_color(_), do: "#64748b"

  defp definition_order do
    RequirementDefinitionData.project_requirements()
    |> Enum.with_index()
    |> Map.new(fn {d, i} -> {d.name, i} end)
  end

  defp story_definition_order do
    RequirementDefinitionData.story_requirements()
    |> Enum.with_index()
    |> Map.new(fn {d, i} -> {d.name, i} end)
  end
end
