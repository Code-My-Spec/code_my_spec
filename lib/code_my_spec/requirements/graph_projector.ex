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
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
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
  Single context graph: context requirements as a vertical chain in the center,
  children fanning out between the container nodes (context_specs, context_implementation).
  """
  @spec component_graph(Scope.t(), String.t()) :: map()
  def component_graph(%Scope{} = scope, component_id) do
    %{nodes: nodes, edges: edges} = Requirements.project_graph(scope)
    actionable = Requirements.next_actionable_project(scope)

    actionable_set =
      MapSet.new(actionable, fn n -> {n.entity_type, n.entity_id, n.name} end)

    components = Components.list_components(scope)
    children = Enum.filter(components, &(&1.parent_component_id == component_id))
    tree_ids = MapSet.new([component_id | Enum.map(children, & &1.id)])

    tree_nodes = Enum.filter(nodes, fn n ->
      n.entity_type == "component" and MapSet.member?(tree_ids, n.entity_id)
    end)

    comp_reqs_by_id = Enum.group_by(tree_nodes, & &1.entity_id)

    req_gap = 400
    child_col_gap = 500
    child_req_gap = 300

    # Context requirements sorted by definition order
    context_reqs = Map.get(comp_reqs_by_id, component_id, [])
    context_type = (Enum.find(components, &(&1.id == component_id)) || %{type: "context"}).type
    ctx_def_order =
      ComponentRegistry.get_requirements_for_type(context_type)
      |> Enum.with_index()
      |> Map.new(fn {d, i} -> {d.name, i} end)

    sorted_ctx_reqs = Enum.sort_by(context_reqs, fn r -> Map.get(ctx_def_order, r.name, 999) end)

    child_count = length(children)
    sorted_children = Enum.sort_by(children, & &1.module_name)

    # Split child reqs into spec phase (spec_file, spec_valid) and impl phase (rest)
    spec_phase_names = MapSet.new(["spec_file", "spec_valid"])

    children_with_reqs =
      Enum.map(sorted_children, fn child ->
        child_defs = ComponentRegistry.get_requirements_for_type(child.type)
        child_def_order =
          child_defs |> Enum.with_index() |> Map.new(fn {d, i} -> {d.name, i} end)

        child_reqs = Map.get(comp_reqs_by_id, child.id, [])
        sorted = Enum.sort_by(child_reqs, fn r -> Map.get(child_def_order, r.name, 999) end)

        spec_reqs = Enum.filter(sorted, fn r -> r.name in spec_phase_names end)
        impl_reqs = Enum.reject(sorted, fn r -> r.name in spec_phase_names end)

        %{child: child, spec_reqs: spec_reqs, impl_reqs: impl_reqs}
      end)

    # Count max rows per phase for gap sizing
    max_spec_rows = children_with_reqs |> Enum.map(fn c -> length(c.spec_reqs) end) |> Enum.max(fn -> 0 end)
    max_impl_rows = children_with_reqs |> Enum.map(fn c -> length(c.impl_reqs) end) |> Enum.max(fn -> 0 end)

    specs_idx = Enum.find_index(sorted_ctx_reqs, &(&1.name == "context_specs"))
    impl_idx = Enum.find_index(sorted_ctx_reqs, &(&1.name == "context_implementation"))

    # Layout context column at x=0, inserting gaps for child zones
    {context_sigma, _y_cursor} =
      sorted_ctx_reqs
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {req, idx}, {acc, y} ->
        node = mk_node(nkey(req), short_req_label(req), 0, -y, 14, cls(req, actionable_set),
          entity_type: "component", entity_id: req.entity_id, name: req.name)

        extra =
          cond do
            idx == specs_idx and child_count > 0 -> (max_spec_rows + 1) * child_req_gap
            idx == impl_idx and child_count > 0 -> (max_impl_rows + 1) * child_req_gap
            true -> 0
          end

        {acc ++ [node], y + req_gap + extra}
      end)

    # Position spec-phase children after context_specs
    specs_y =
      if specs_idx do
        ctx_node = Enum.at(context_sigma, specs_idx)
        if ctx_node, do: ctx_node.attributes.y, else: 0
      else
        0
      end

    spec_child_sigma =
      children_with_reqs
      |> Enum.with_index()
      |> Enum.flat_map(fn {cwr, col_idx} ->
        x = (col_idx - (child_count - 1) / 2) * child_col_gap

        cwr.spec_reqs
        |> Enum.with_index()
        |> Enum.map(fn {req, req_idx} ->
          y = specs_y - ((req_idx + 1) * child_req_gap)
          mk_node(nkey(req), short_req_label(req), x, y, 10, cls(req, actionable_set),
            entity_type: "component", entity_id: req.entity_id, name: req.name)
        end)
      end)

    # Position impl-phase children after context_implementation
    impl_y =
      if impl_idx do
        ctx_node = Enum.at(context_sigma, impl_idx)
        if ctx_node, do: ctx_node.attributes.y, else: 0
      else
        0
      end

    impl_child_sigma =
      children_with_reqs
      |> Enum.with_index()
      |> Enum.flat_map(fn {cwr, col_idx} ->
        x = (col_idx - (child_count - 1) / 2) * child_col_gap

        cwr.impl_reqs
        |> Enum.with_index()
        |> Enum.map(fn {req, req_idx} ->
          y = impl_y - ((req_idx + 1) * child_req_gap)
          mk_node(nkey(req), short_req_label(req), x, y, 10, cls(req, actionable_set),
            entity_type: "component", entity_id: req.entity_id, name: req.name)
        end)
      end)

    all_sigma = context_sigma ++ spec_child_sigma ++ impl_child_sigma
    all_keys = MapSet.new(all_sigma, & &1.key)

    # Edges: filter to this tree, both directions
    tree_node_keys = MapSet.new(tree_nodes, fn n -> {n.entity_type, n.entity_id, n.name} end)

    sigma_edges =
      edges
      |> Enum.filter(fn e ->
        MapSet.member?(tree_node_keys, e.from) and MapSet.member?(tree_node_keys, e.to)
      end)
      |> Enum.map(fn e ->
        {key_to_string(e.from), key_to_string(e.to), e}
      end)
      |> Enum.filter(fn {f, t, _} -> MapSet.member?(all_keys, f) and MapSet.member?(all_keys, t) end)
      |> Enum.uniq_by(fn {f, t, _} -> {f, t} end)
      |> Enum.reject(fn {f, t, _} -> f == t end)
      |> Enum.map(fn {f, t, _e} ->
        %{key: "#{f}->#{t}", source: f, target: t,
          attributes: %{size: 2, color: "#64748b", type: "arrow"}}
      end)

    %{nodes: all_sigma, edges: sigma_edges}
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

    # Random initial positions — sigma + force layout will organize naturally
    sigma_nodes =
      all_groups
      |> Enum.map(fn {comp_id, group} ->
        reqs = group.reqs
        sat = Enum.count(reqs, & &1.satisfied)
        total = length(reqs)
        name = short_module(group.component.module_name)
        size = 8

        mk_node(summary_key(comp_id), "#{name} #{sat}/#{total}",
          :rand.uniform(5000) - 2500, :rand.uniform(5000) - 2500, size,
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

    %{nodes: sigma_nodes, edges: dep_edges, layout: "force"}
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

  defp short_req_label(n) do
    mod = n.entity_name |> String.split(".") |> List.last()
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
