defmodule CodeMySpec.Requirements.GraphProjector do
  @moduledoc """
  Projects the computed requirement graph into a JSON structure for sigma.js.

  Layout is horizontal layers:
  1. Project chain (vertical, centered)
  2. Stories as columns: component_linked + bdd_specs_exist
  3. Component zone: full requirement chains per context/component
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
  # @comp_gap and @comp_zone_height removed — component zone is now dynamic

  @context_types MapSet.new(["context", "live_context", "controller"])
  @pre_component_reqs ["component_linked", "bdd_specs_exist"]
  @post_component_reqs ["bdd_specs_passing", "qa_complete"]

  # Type priority for dependency ordering: lower = rendered first (no deps)
  @type_priority %{
    "schema" => 0,
    "behaviour" => 1,
    "repository" => 2,
    "service" => 3,
    "liveview" => 4,
    "liveview_component" => 4,
    "json" => 4
  }

  @spec project_graph(Scope.t()) :: map()
  def project_graph(%Scope{} = scope) do
    %{nodes: nodes, edges: edges} = Requirements.project_graph(scope)
    actionable = Requirements.next_actionable_project(scope)

    actionable_set =
      MapSet.new(actionable, fn n -> {n.entity_type, n.entity_id, n.name} end)

    components = Components.list_components_with_dependencies(scope)

    comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component"))
    comp_reqs_by_id = Enum.group_by(comp_nodes, & &1.entity_id)

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
        mk_node(nkey(n), label(n), 0, -(idx * @row_gap), 12, cls(n, actionable_set),
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
          mk_node(nkey(req), story_label(req), x, y, 8, cls(req, actionable_set),
            entity_type: "story", entity_id: req.entity_id, name: req.name)
        end)
      end)

    # --- Layer 3: Expanded component zone (layered by dependency depth) ---
    comp_zone_y = story_start_y - (length(@pre_component_reqs) * @story_row_gap) - @row_gap

    # Identify top-level groups: parent components (with children) and standalones
    parent_ids = components |> Enum.map(& &1.parent_component_id) |> MapSet.new() |> MapSet.delete(nil)
    child_ids = components |> Enum.filter(&(&1.parent_component_id && MapSet.member?(parent_ids, &1.parent_component_id))) |> MapSet.new(& &1.id)

    # Top-level = parents + standalones (not children)
    top_level =
      components
      |> Enum.filter(fn c -> !MapSet.member?(child_ids, c.id) end)
      |> Enum.sort_by(& &1.module_name)

    # Compute dependency depth for each top-level component
    dep_depth = compute_dependency_depths(top_level)

    # Group by depth tier, sort tiers deepest-first (depth 0 = no deps = rendered first/top)
    tiers =
      top_level
      |> Enum.group_by(fn c -> Map.get(dep_depth, c.id, 0) end)
      |> Enum.sort_by(fn {depth, _} -> depth end)

    # Layout each tier as a horizontal band, stacking downward
    {comp_sigma, comp_zone_total_height} =
      Enum.reduce(tiers, {[], comp_zone_y}, fn {_depth, tier_components}, {all_nodes, tier_y} ->
        tree_layouts =
          Enum.map(
            tier_components,
            &tree_layout_for_top_level(&1, parent_ids, components, comp_reqs_by_id, actionable_set)
          )

        {tier_nodes, tier_height} = place_component_trees(tree_layouts, tier_y)
        {all_nodes ++ tier_nodes, tier_y - tier_height - @row_gap}
      end)
      |> then(fn {nodes, final_y} -> {nodes, comp_zone_y - final_y} end)

    # --- Layer 4: Post-component story reqs ---
    post_zone_y = comp_zone_y - comp_zone_total_height - @row_gap

    post_sigma =
      Enum.flat_map(sorted_stories, fn {{_id, reqs}, col_idx} ->
        sorted_reqs = Enum.sort_by(reqs, fn r -> Map.get(story_order, r.name, 999) end)
        x = (col_idx - (story_count - 1) / 2) * @story_col_gap
        post = Enum.filter(sorted_reqs, &(&1.name in @post_component_reqs))

        post
        |> Enum.with_index()
        |> Enum.map(fn {req, idx} ->
          y = post_zone_y - (idx * @story_row_gap)
          mk_node(nkey(req), story_label(req), x, y, 8, cls(req, actionable_set),
            entity_type: "story", entity_id: req.entity_id, name: req.name)
        end)
      end)

    # --- Layer 5: Late project chain ---
    late_start_y = post_zone_y - (length(@post_component_reqs) * @story_row_gap) - @row_gap

    late_sigma =
      late_project
      |> Enum.with_index()
      |> Enum.map(fn {n, idx} ->
        mk_node(nkey(n), label(n), 0, late_start_y - (idx * @row_gap), 12, cls(n, actionable_set),
          entity_type: "project", name: n.name)
      end)

    all_sigma = early_sigma ++ pre_sigma ++ comp_sigma ++ post_sigma ++ late_sigma
    all_keys = MapSet.new(all_sigma, & &1.key)

    raw_edges = Enum.map(edges, fn e -> {key_to_string(e.from), key_to_string(e.to), e} end)

    orphan_source_keys = orphan_reference_source_keys(raw_edges, all_keys)
    all_sigma = mark_orphan_references(all_sigma, orphan_source_keys)

    sigma_edges =
      raw_edges
      |> Enum.filter(fn {f, t, _} -> MapSet.member?(all_keys, f) and MapSet.member?(all_keys, t) end)
      |> Enum.uniq_by(fn {f, t, _} -> {f, t} end)
      |> Enum.reject(fn {f, t, _} -> f == t end)
      |> Enum.map(fn {f, t, e} ->
        %{key: "#{f}->#{t}", source: f, target: t,
          attributes: %{size: 2, color: edge_color(e), type: "arrow"}}
      end)

    %{nodes: all_sigma, edges: sigma_edges}
  end

  # Source keys of edges whose target is missing from the rendered set.
  # Story 562 surfaces these as `orphan_reference: true` rather than silently
  # dropping the edge — matches the rule "edges trace back to real nodes."
  defp orphan_reference_source_keys(raw_edges, all_keys) do
    raw_edges
    |> Enum.filter(fn {f, t, _} -> MapSet.member?(all_keys, f) and not MapSet.member?(all_keys, t) end)
    |> MapSet.new(fn {f, _, _} -> f end)
  end

  defp mark_orphan_references(nodes, orphan_keys) do
    Enum.map(nodes, fn node ->
      attrs =
        Map.put(
          node.attributes,
          :orphan_reference,
          MapSet.member?(orphan_keys, node.key)
        )

      %{node | attributes: attrs}
    end)
  end

  @doc """
  Single context graph: context requirements as a vertical chain in the center,
  children fanning out between the phase gate nodes (spec_valid, review_valid).
  """
  @spec component_graph(Scope.t(), String.t()) :: map()
  def component_graph(%Scope{} = scope, component_id) do
    %{nodes: nodes, edges: edges} = Requirements.project_graph(scope)
    actionable_set = build_actionable_set(scope)

    components = Components.list_components(scope)
    children = Enum.filter(components, &(&1.parent_component_id == component_id))
    tree_ids = MapSet.new([component_id | Enum.map(children, & &1.id)])
    tree_nodes = filter_tree_nodes(nodes, tree_ids)
    comp_reqs_by_id = Enum.group_by(tree_nodes, & &1.entity_id)

    layout = %{req_gap: 400, child_col_gap: 500, child_req_gap: 300}

    context_type = component_type(components, component_id)
    sorted_ctx_reqs = sort_context_reqs(comp_reqs_by_id, component_id, context_type)
    sorted_children = sort_children_by_dependency(children, components)
    children_with_reqs = partition_children_reqs(sorted_children, comp_reqs_by_id, context_type)

    {context_sigma, specs_y, impl_y} =
      build_context_column(sorted_ctx_reqs, children_with_reqs, layout, actionable_set, 14)

    spec_child_sigma =
      build_phase_child_sigma(children_with_reqs, :spec_reqs, specs_y, layout, actionable_set, 10)

    impl_child_sigma =
      build_phase_child_sigma(children_with_reqs, :impl_reqs, impl_y, layout, actionable_set, 10)

    all_sigma = context_sigma ++ spec_child_sigma ++ impl_child_sigma
    sigma_edges = component_graph_edges(edges, tree_nodes, all_sigma)

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
      |> Enum.flat_map(&group_dep_edges(&1, child_to_context, all_keys))
      |> Enum.uniq_by(& &1.key)

    %{nodes: sigma_nodes, edges: dep_edges, layout: "force"}
  end

  # -- Expanded component tree layout --

  @ctx_req_gap 250
  @child_col_gap 350
  @child_req_gap 200
  @tree_gap 300
  @spec_phase_names MapSet.new(["spec_file", "spec_valid"])

  # Layout a context and its children as a tree. Returns {nodes, width, height}
  # with positions relative to (0, 0) origin.
  defp layout_context_tree_nodes(context, components, comp_reqs_by_id, actionable_set) do
    children =
      components
      |> Enum.filter(&(&1.parent_component_id == context.id))
      |> sort_children_by_dependency(components)

    sorted_ctx = sort_context_reqs(comp_reqs_by_id, context.id, context.type)
    children_with_reqs = partition_children_reqs(children, comp_reqs_by_id, context.type)

    layout = %{req_gap: @ctx_req_gap, child_col_gap: @child_col_gap, child_req_gap: @child_req_gap}

    {ctx_nodes, y_cursor, specs_y, impl_y} =
      build_context_column_with_cursor(sorted_ctx, children_with_reqs, layout, actionable_set, 8, &comp_label/1)

    spec_child_nodes =
      build_phase_child_sigma_with_label(
        children_with_reqs, :spec_reqs, specs_y, layout, actionable_set, 5, &comp_label/1)

    impl_child_nodes =
      build_phase_child_sigma_with_label(
        children_with_reqs, :impl_reqs, impl_y, layout, actionable_set, 5, &comp_label/1)

    all_nodes = ctx_nodes ++ spec_child_nodes ++ impl_child_nodes
    child_count = length(children)
    width = if child_count == 0, do: 0, else: child_count * @child_col_gap
    {all_nodes, width, y_cursor}
  end

  # Layout a standalone component (not a context, not a child) as a simple vertical chain.
  defp layout_standalone_nodes(comp, comp_reqs_by_id, actionable_set) do
    reqs = Map.get(comp_reqs_by_id, comp.id, [])
    def_order =
      ComponentRegistry.get_requirements_for_type(comp.type)
      |> Enum.with_index()
      |> Map.new(fn {d, i} -> {d.name, i} end)

    sorted = Enum.sort_by(reqs, fn r -> Map.get(def_order, r.name, 999) end)

    nodes =
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {req, idx} ->
        mk_node(nkey(req), comp_label(req), 0, -(idx * @ctx_req_gap), 6, cls(req, actionable_set),
          entity_type: "component", entity_id: req.entity_id, name: req.name)
      end)

    height = max(length(sorted) - 1, 0) * @ctx_req_gap
    {nodes, 0, height}
  end

  # Compute dependency depth for top-level components.
  # Depth 0 = no dependencies (or deps are all children, not top-level).
  # Depth N = max(dep depths) + 1.
  defp compute_dependency_depths(top_level) do
    top_level_ids = MapSet.new(top_level, & &1.id)

    # Build adjacency: component_id → list of dependency component_ids (only top-level deps)
    dep_graph =
      Map.new(top_level, fn comp ->
        deps = case comp.dependencies do
          %Ecto.Association.NotLoaded{} -> []
          deps when is_list(deps) -> deps
          _ -> []
        end

        dep_ids = deps |> Enum.map(& &1.id) |> Enum.filter(&MapSet.member?(top_level_ids, &1))
        {comp.id, dep_ids}
      end)

    # Iterative depth computation (handles DAGs)
    initial = Map.new(top_level, fn c -> {c.id, if(dep_graph[c.id] == [], do: 0, else: nil)} end)
    resolve_depths(initial, dep_graph)
  end

  defp resolve_depths(depths, dep_graph) do
    updated = Enum.reduce(depths, depths, &resolve_depth_step(&1, &2, dep_graph))

    if updated == depths do
      # No progress — remaining nils get depth 0 (circular deps or missing)
      Map.new(updated, fn {id, d} -> {id, d || 0} end)
    else
      resolve_depths(updated, dep_graph)
    end
  end

  defp resolve_depth_step({_id, depth}, acc, _dep_graph) when not is_nil(depth), do: acc

  defp resolve_depth_step({id, _depth}, acc, dep_graph) do
    dep_depths = Enum.map(dep_graph[id] || [], &Map.get(acc, &1))

    if Enum.all?(dep_depths, &(not is_nil(&1))) do
      Map.put(acc, id, Enum.max(dep_depths, fn -> 0 end) + 1)
    else
      acc
    end
  end

  # Arrange tree layouts side by side, centered around x=0, offset to comp_zone_y.
  defp place_component_trees([], _comp_zone_y), do: {[], 0}

  defp place_component_trees(tree_layouts, comp_zone_y) do
    widths = Enum.map(tree_layouts, fn {_, w, _} -> max(w, 200) end)
    total_width = Enum.sum(widths) + (length(widths) - 1) * @tree_gap

    {all_nodes, _x, max_height} =
      tree_layouts
      |> Enum.zip(widths)
      |> Enum.reduce({[], -total_width / 2, 0}, &place_one_tree(&1, &2, comp_zone_y))

    {all_nodes, max_height}
  end

  defp place_one_tree({{nodes, _w, height}, effective_w}, {acc, x, max_h}, comp_zone_y) do
    center_x = x + effective_w / 2
    offset_nodes = offset_tree_nodes(nodes, center_x, comp_zone_y)
    {acc ++ offset_nodes, x + effective_w + @tree_gap, max(max_h, height)}
  end

  defp offset_tree_nodes(nodes, center_x, comp_zone_y) do
    Enum.map(nodes, fn node ->
      attrs = node.attributes
      %{node | attributes: %{attrs | x: attrs.x + center_x, y: attrs.y + comp_zone_y}}
    end)
  end

  # Sort children by dependency depth within their sibling group.
  # Uses explicit dependency edges when available, falls back to type priority.
  defp sort_children_by_dependency(children, all_components) do
    child_ids = MapSet.new(children, & &1.id)
    sibling_deps = Map.new(children, &{&1.id, child_sibling_deps(&1, all_components, child_ids)})

    initial = Map.new(children, fn c ->
      {c.id, if(sibling_deps[c.id] == [], do: 0, else: nil)}
    end)

    depths = resolve_depths(initial, sibling_deps)

    Enum.sort_by(children, fn c ->
      {Map.get(depths, c.id, 0), Map.get(@type_priority, c.type, 5), c.module_name}
    end)
  end

  defp child_sibling_deps(%{dependencies: deps}, _all_components, child_ids) when is_list(deps) do
    filter_dep_ids(deps, child_ids)
  end

  defp child_sibling_deps(child, all_components, child_ids) do
    case Enum.find(all_components, &(&1.id == child.id)) do
      %{dependencies: deps} when is_list(deps) -> filter_dep_ids(deps, child_ids)
      _ -> []
    end
  end

  defp filter_dep_ids(deps, allowed_ids) do
    deps |> Enum.map(& &1.id) |> Enum.filter(&MapSet.member?(allowed_ids, &1))
  end

  # Build a definition order map for :child nodes from the context template.
  # This ensures all children use the same phase→index mapping regardless of
  # their own component type, so Y levels are consistent across columns.
  defp context_child_definition_order(context_type) do
    RequirementDefinitionData.graph_for_type(context_type)
    |> Enum.filter(fn d -> d.node_scope == :child end)
    |> Enum.uniq_by(& &1.name)
    |> Enum.with_index()
    |> Map.new(fn {d, i} -> {d.name, i} end)
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

  # -- Shared layout helpers --

  defp build_actionable_set(scope) do
    Requirements.next_actionable_project(scope)
    |> MapSet.new(fn n -> {n.entity_type, n.entity_id, n.name} end)
  end

  defp filter_tree_nodes(nodes, tree_ids) do
    Enum.filter(nodes, fn n ->
      n.entity_type == "component" and MapSet.member?(tree_ids, n.entity_id)
    end)
  end

  defp component_type(components, component_id) do
    (Enum.find(components, &(&1.id == component_id)) || %{type: "context"}).type
  end

  defp definition_index(component_type) do
    ComponentRegistry.get_requirements_for_type(component_type)
    |> Enum.with_index()
    |> Map.new(fn {d, i} -> {d.name, i} end)
  end

  defp sort_context_reqs(comp_reqs_by_id, component_id, context_type) do
    reqs = Map.get(comp_reqs_by_id, component_id, [])
    ctx_def_order = definition_index(context_type)
    Enum.sort_by(reqs, fn r -> Map.get(ctx_def_order, r.name, 999) end)
  end

  defp partition_children_reqs(sorted_children, comp_reqs_by_id, context_type) do
    child_def_order = context_child_definition_order(context_type)

    Enum.map(sorted_children, fn child ->
      child_reqs = Map.get(comp_reqs_by_id, child.id, [])
      sorted = Enum.sort_by(child_reqs, fn r -> Map.get(child_def_order, r.name, 999) end)

      %{
        child: child,
        spec_reqs: Enum.filter(sorted, &(&1.name in @spec_phase_names)),
        impl_reqs: Enum.reject(sorted, &(&1.name in @spec_phase_names))
      }
    end)
  end

  defp max_phase_rows(children_with_reqs, key) do
    children_with_reqs |> Enum.map(&length(Map.fetch!(&1, key))) |> Enum.max(fn -> 0 end)
  end

  defp build_context_column(sorted_ctx_reqs, children_with_reqs, layout, actionable_set, size) do
    {nodes, _y_cursor, specs_y, impl_y} =
      build_context_column_with_cursor(
        sorted_ctx_reqs, children_with_reqs, layout, actionable_set, size, &short_req_label/1)

    {nodes, specs_y, impl_y}
  end

  defp build_context_column_with_cursor(sorted_ctx_reqs, children_with_reqs, layout, actionable_set, size, label_fn) do
    child_count = length(children_with_reqs)
    max_spec = max_phase_rows(children_with_reqs, :spec_reqs)
    max_impl = max_phase_rows(children_with_reqs, :impl_reqs)
    specs_idx = Enum.find_index(sorted_ctx_reqs, &(&1.name == "spec_valid"))
    impl_idx = Enum.find_index(sorted_ctx_reqs, &(&1.name == "review_valid"))

    state = %{
      layout: layout,
      actionable_set: actionable_set,
      size: size,
      label_fn: label_fn,
      specs_idx: specs_idx,
      impl_idx: impl_idx,
      child_count: child_count,
      max_spec: max_spec,
      max_impl: max_impl
    }

    {nodes, y_cursor} =
      sorted_ctx_reqs
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, &context_column_step(&1, &2, state))

    {nodes, y_cursor, phase_y(nodes, specs_idx), phase_y(nodes, impl_idx)}
  end

  defp context_column_step({req, idx}, {acc, y}, state) do
    node =
      mk_node(
        nkey(req),
        state.label_fn.(req),
        0,
        -y,
        state.size,
        cls(req, state.actionable_set),
        entity_type: "component",
        entity_id: req.entity_id,
        name: req.name
      )

    extra = column_extra_y(idx, state)
    {acc ++ [node], y + state.layout.req_gap + extra}
  end

  defp column_extra_y(idx, %{specs_idx: idx, child_count: c} = state) when c > 0,
    do: (state.max_spec + 1) * state.layout.child_req_gap

  defp column_extra_y(idx, %{impl_idx: idx, child_count: c} = state) when c > 0,
    do: (state.max_impl + 1) * state.layout.child_req_gap

  defp column_extra_y(_idx, _state), do: 0

  defp phase_y(_nodes, nil), do: 0

  defp phase_y(nodes, idx) do
    case Enum.at(nodes, idx) do
      nil -> 0
      node -> node.attributes.y
    end
  end

  defp build_phase_child_sigma(children_with_reqs, phase, base_y, layout, actionable_set, size) do
    build_phase_child_sigma_with_label(
      children_with_reqs, phase, base_y, layout, actionable_set, size, &short_req_label/1)
  end

  defp build_phase_child_sigma_with_label(children_with_reqs, phase, base_y, layout, actionable_set, size, label_fn) do
    child_count = length(children_with_reqs)

    children_with_reqs
    |> Enum.with_index()
    |> Enum.flat_map(&child_phase_nodes(&1, phase, base_y, layout, actionable_set, size, label_fn, child_count))
  end

  defp child_phase_nodes({cwr, col_idx}, phase, base_y, layout, actionable_set, size, label_fn, child_count) do
    x = (col_idx - (child_count - 1) / 2) * layout.child_col_gap

    cwr
    |> Map.fetch!(phase)
    |> Enum.with_index()
    |> Enum.map(fn {req, req_idx} ->
      y = base_y - (req_idx + 1) * layout.child_req_gap

      mk_node(nkey(req), label_fn.(req), x, y, size, cls(req, actionable_set),
        entity_type: "component", entity_id: req.entity_id, name: req.name)
    end)
  end

  defp component_graph_edges(edges, tree_nodes, all_sigma) do
    tree_node_keys = MapSet.new(tree_nodes, fn n -> {n.entity_type, n.entity_id, n.name} end)
    all_keys = MapSet.new(all_sigma, & &1.key)

    edges
    |> Enum.filter(fn e ->
      MapSet.member?(tree_node_keys, e.from) and MapSet.member?(tree_node_keys, e.to)
    end)
    |> Enum.map(fn e -> {key_to_string(e.from), key_to_string(e.to), e} end)
    |> Enum.filter(fn {f, t, _} -> MapSet.member?(all_keys, f) and MapSet.member?(all_keys, t) end)
    |> Enum.uniq_by(fn {f, t, _} -> {f, t} end)
    |> Enum.reject(fn {f, t, _} -> f == t end)
    |> Enum.map(fn {f, t, _e} ->
      %{
        key: "#{f}->#{t}",
        source: f,
        target: t,
        attributes: %{size: 2, color: "#64748b", type: "arrow"}
      }
    end)
  end

  defp tree_layout_for_top_level(comp, parent_ids, components, comp_reqs_by_id, actionable_set) do
    if MapSet.member?(parent_ids, comp.id) do
      layout_context_tree_nodes(comp, components, comp_reqs_by_id, actionable_set)
    else
      layout_standalone_nodes(comp, comp_reqs_by_id, actionable_set)
    end
  end

  defp group_dep_edges({_id, group}, child_to_context, all_keys) do
    from_key = summary_key(group.component.id)
    deps = group.component.dependencies || []
    Enum.flat_map(deps, &dep_edge(&1, from_key, child_to_context, all_keys))
  end

  defp dep_edge(dep, from_key, child_to_context, all_keys) do
    to_key = summary_key(Map.get(child_to_context, dep.id, dep.id))

    if to_key != from_key and MapSet.member?(all_keys, to_key) do
      [
        %{
          key: "dep_#{from_key}->#{to_key}",
          source: from_key,
          target: to_key,
          attributes: %{size: 2, color: "#6366f1", type: "arrow"}
        }
      ]
    else
      []
    end
  end
end
