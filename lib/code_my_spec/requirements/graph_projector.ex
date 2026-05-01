defmodule CodeMySpec.Requirements.GraphProjector do
  @moduledoc """
  Projects the computed requirement graph into a JSON structure for sigma.js.

  Layout is derived purely from `Topology` facts — entity-type
  partitions, cross-entity edges, fan-in/fan-out points, and
  topological depth. The projector reads no requirement names
  and no template data: every layout decision asks the graph
  itself "is this node a fan-in?", "does it bridge entity types?",
  "what's its depth?". Domain meaning lives on each node's FK
  fields (`entity_type`, `entity_id`, `parent_entity_id`).

  Horizontal bands, top-to-bottom:

  1. Project nodes upstream of any cross-entity edge (early chain).
  2. Story bridge nodes upstream of any component
     (cross-entity sources/sinks not downstream of components).
  3. Component zone — one tree per top-level component, sized
     dynamically by child count and phase break depth.
  4. Story bridge nodes downstream of components.
  5. Project nodes downstream of stories (late chain).

  Phase breaks within a context tree are detected via
  `Topology.fans_out_to_children?/3` — wherever a parent-scope
  node has same-`entity_type` outgoing edges to nodes with a
  different `entity_id`.
  """

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Topology
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

  @spec project_graph(Scope.t()) :: map()
  def project_graph(%Scope{} = scope) do
    %{nodes: nodes, edges: edges} = Requirements.project_graph(scope)
    actionable = Requirements.next_actionable_project(scope)

    actionable_set =
      MapSet.new(actionable, &node_key/1)

    components = Components.list_components_with_dependencies(scope)

    comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component"))
    comp_reqs_by_id = Enum.group_by(comp_nodes, & &1.entity_id)

    project_nodes = Enum.filter(nodes, &(&1.entity_type == "project"))
    story_nodes = Enum.filter(nodes, &(&1.entity_type == "story"))

    # Topology facts (no name lookups, no template reads).
    topo = build_topo(nodes, edges)
    cross_sinks = Topology.cross_entity_sinks(nodes, edges) |> MapSet.new(&node_key/1)
    component_descendants = Topology.descendants_of(comp_nodes, edges)

    sorted_project = sort_by_depth(project_nodes, topo)

    # Project chain splits where cross-entity edges first land on a
    # project node — that's the structural fan-in seam, no need to
    # name the requirement.
    fan_in_idx =
      Enum.find_index(sorted_project, fn n -> MapSet.member?(cross_sinks, node_key(n)) end) || 0

    {early_project, late_project} = Enum.split(sorted_project, fan_in_idx)

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

    # Pre-component story nodes: every story node that is NOT
    # downstream of any component. This includes purely-internal
    # story nodes (e.g., three_amigos_complete) as well as the
    # bridge sources/sinks that connect to project / component.
    # Hiding non-bridge nodes used to be the rule; with the
    # restructured story chain (component_linked → three_amigos_complete
    # → bdd_specs_exist) those internal hops are load-bearing and
    # belong on the canvas.
    pre_sigma =
      Enum.flat_map(sorted_stories, fn {{_id, reqs}, col_idx} ->
        sorted_reqs = sort_by_depth(reqs, topo)
        x = (col_idx - (story_count - 1) / 2) * @story_col_gap

        pre =
          Enum.reject(sorted_reqs, fn r ->
            MapSet.member?(component_descendants, node_key(r))
          end)

        pre
        |> Enum.with_index()
        |> Enum.map(fn {req, idx} ->
          y = story_start_y - (idx * @story_row_gap)
          mk_node(nkey(req), story_label(req), x, y, 8, cls(req, actionable_set),
            entity_type: "story", entity_id: req.entity_id, name: req.name)
        end)
      end)

    # --- Layer 3: Expanded component zone (layered by dependency depth) ---
    pre_height = pre_sigma |> Enum.map(& &1.attributes.y) |> Enum.min(fn -> story_start_y end)
    comp_zone_y = pre_height - @story_row_gap - @row_gap

    # Identify top-level groups: container components (context-shaped types
    # with :child scope defs) and standalones. A `parent_component_id` only
    # rolls a component into its parent's tree when the parent is a real
    # container — otherwise the parent is just a namespace umbrella
    # (e.g. an `infrastructure`-typed `MarketMySpec`) and the child is
    # itself top-level.
    container_ids =
      components
      |> Enum.filter(&ComponentRegistry.has_children?(&1.type))
      |> MapSet.new(& &1.id)

    parent_ids = container_ids
    child_ids = components |> Enum.filter(&(&1.parent_component_id && MapSet.member?(container_ids, &1.parent_component_id))) |> MapSet.new(& &1.id)

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
            &tree_layout_for_top_level(&1, parent_ids, components, comp_reqs_by_id, actionable_set, topo)
          )

        {tier_nodes, tier_height} = place_component_trees(tree_layouts, tier_y)
        {all_nodes ++ tier_nodes, tier_y - tier_height - @row_gap}
      end)
      |> then(fn {nodes, final_y} -> {nodes, comp_zone_y - final_y} end)

    # --- Layer 4: Post-component story reqs ---
    post_zone_y = comp_zone_y - comp_zone_total_height - @row_gap

    post_sigma =
      Enum.flat_map(sorted_stories, fn {{_id, reqs}, col_idx} ->
        sorted_reqs = sort_by_depth(reqs, topo)
        x = (col_idx - (story_count - 1) / 2) * @story_col_gap

        post =
          Enum.filter(sorted_reqs, fn r ->
            MapSet.member?(component_descendants, node_key(r))
          end)

        post
        |> Enum.with_index()
        |> Enum.map(fn {req, idx} ->
          y = post_zone_y - (idx * @story_row_gap)
          mk_node(nkey(req), story_label(req), x, y, 8, cls(req, actionable_set),
            entity_type: "story", entity_id: req.entity_id, name: req.name)
        end)
      end)

    # --- Layer 5: Late project chain ---
    post_lowest_y = post_sigma |> Enum.map(& &1.attributes.y) |> Enum.min(fn -> post_zone_y end)
    late_start_y = post_lowest_y - @story_row_gap - @row_gap

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
  Single context graph: the context's requirements as a vertical
  chain in the centre, with children fanning out at each parent
  fan-out point (the structural phase break — see
  `Topology.fans_out_to_children?/3`).
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
    topo = build_topo(nodes, edges)

    sorted_ctx_reqs = sort_context_reqs(comp_reqs_by_id, component_id, topo)
    sorted_children = sort_children_by_dependency(children, components)
    children_with_reqs = partition_children_reqs(sorted_children, comp_reqs_by_id, component_id, topo)

    {context_sigma, specs_y, impl_y} =
      build_context_column(sorted_ctx_reqs, children_with_reqs, layout, actionable_set, 14, topo)

    spec_child_sigma =
      build_phase_child_sigma(children_with_reqs, :spec_reqs, specs_y, layout, actionable_set, 10)

    impl_child_sigma =
      build_phase_child_sigma(children_with_reqs, :impl_reqs, impl_y, layout, actionable_set, 10)

    all_sigma = context_sigma ++ spec_child_sigma ++ impl_child_sigma
    sigma_edges = component_graph_edges(edges, tree_nodes, all_sigma)

    %{nodes: all_sigma, edges: sigma_edges}
  end

  defp build_topo(nodes, edges) do
    %{
      nodes: nodes,
      edges: edges,
      depth: Topology.depth_map(nodes, edges),
      fan_out_keys: Topology.fan_out_keys(nodes, edges)
    }
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
      MapSet.new(actionable, &node_key/1)

    comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component"))
    comp_reqs_by_id = Enum.group_by(comp_nodes, & &1.entity_id)

    components = Components.list_components_with_dependencies(scope)

    context_ids =
      components
      |> Enum.filter(fn c -> ComponentRegistry.has_children?(c.type) end)
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

  # Layout a context and its children as a tree. Returns {nodes, width, height}
  # with positions relative to (0, 0) origin.
  defp layout_context_tree_nodes(context, components, comp_reqs_by_id, actionable_set, topo) do
    children =
      components
      |> Enum.filter(&(&1.parent_component_id == context.id))
      |> sort_children_by_dependency(components)

    sorted_ctx = sort_context_reqs(comp_reqs_by_id, context.id, topo)
    children_with_reqs = partition_children_reqs(children, comp_reqs_by_id, context.id, topo)

    layout = %{req_gap: @ctx_req_gap, child_col_gap: @child_col_gap, child_req_gap: @child_req_gap}

    {ctx_nodes, y_cursor, specs_y, impl_y} =
      build_context_column_with_cursor(sorted_ctx, children_with_reqs, layout, actionable_set, 8, &comp_label/1, topo)

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
  defp layout_standalone_nodes(comp, comp_reqs_by_id, actionable_set, topo) do
    reqs = Map.get(comp_reqs_by_id, comp.id, [])
    sorted = sort_by_depth(reqs, topo)

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
      {Map.get(depths, c.id, 0), ComponentRegistry.dependency_order(c.type), c.module_name}
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

  defp node_key(n), do: Topology.node_key(n)
  defp nkey(n), do: key_to_string(node_key(n))
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
    if MapSet.member?(actionable_set, node_key(n)), do: :actionable, else: :blocked
  end

  defp summary_status(reqs, actionable_set) do
    sat = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)
    cond do
      sat == total and total > 0 -> :satisfied
      Enum.any?(reqs, fn r -> MapSet.member?(actionable_set, node_key(r)) end) -> :actionable
      true -> :blocked
    end
  end

  defp color(:satisfied), do: @colors.satisfied
  defp color(:actionable), do: @colors.actionable
  defp color(:blocked), do: @colors.blocked
  defp color(_), do: @colors.blocked

  defp edge_color(%{from: {ft, _, _}, to: {tt, _, _}}) when ft != tt, do: "#818cf8"
  defp edge_color(_), do: "#64748b"

  # -- Shared layout helpers --

  defp build_actionable_set(scope) do
    Requirements.next_actionable_project(scope)
    |> MapSet.new(&node_key/1)
  end

  defp filter_tree_nodes(nodes, tree_ids) do
    Enum.filter(nodes, fn n ->
      n.entity_type == "component" and MapSet.member?(tree_ids, n.entity_id)
    end)
  end

  defp sort_context_reqs(comp_reqs_by_id, component_id, topo) do
    comp_reqs_by_id
    |> Map.get(component_id, [])
    |> sort_by_depth(topo)
  end

  defp sort_by_depth(reqs, topo) do
    Enum.sort_by(reqs, &Map.get(topo.depth, node_key(&1), 0))
  end

  # Cluster a child's reqs into spec-phase vs impl-phase by which
  # parent fan-out point feeds them. Spec-phase = reachable from the
  # FIRST fan-out point (in depth order); impl-phase = reachable
  # from the SECOND fan-out point. Anything else (a child req with
  # no fan-out ancestor) falls into impl_reqs as a safe default —
  # nothing in the current templates produces such a req.
  defp partition_children_reqs(sorted_children, comp_reqs_by_id, parent_id, topo) do
    fan_outs_by_depth = fan_out_nodes_by_depth(parent_id, topo)
    {first_fo_descendants, second_fo_descendants} = phase_descendant_sets(fan_outs_by_depth, topo)

    Enum.map(sorted_children, fn child ->
      child_reqs = Map.get(comp_reqs_by_id, child.id, [])
      sorted = sort_by_depth(child_reqs, topo)

      {spec_reqs, impl_reqs} = split_child_reqs(sorted, fan_outs_by_depth, first_fo_descendants, second_fo_descendants)

      %{child: child, spec_reqs: spec_reqs, impl_reqs: impl_reqs}
    end)
  end

  # When the parent's surviving chain has no fan-out points (e.g. a
  # configuration that disables every artifact type that would
  # otherwise fan out), the descendant sets are empty and every child
  # req would be dropped from both bands. Treat those children as
  # impl-phase so they still land on the canvas — the impl band is the
  # default anchor and `build_phase_child_sigma` happily places them
  # at `phase_y(nodes, nil) == 0`.
  defp split_child_reqs(sorted, [], _first, _second), do: {[], sorted}

  defp split_child_reqs(sorted, _fan_outs, first_fo_descendants, second_fo_descendants) do
    {spec_reqs, rest} =
      Enum.split_with(sorted, &MapSet.member?(first_fo_descendants, node_key(&1)))

    impl_reqs = Enum.filter(rest, &MapSet.member?(second_fo_descendants, node_key(&1)))
    {spec_reqs, impl_reqs}
  end

  defp fan_out_nodes_by_depth(parent_id, topo) do
    topo.nodes
    |> Enum.filter(fn n ->
      n.entity_id == parent_id and MapSet.member?(topo.fan_out_keys, node_key(n))
    end)
    |> sort_by_depth(topo)
  end

  # Current layout supports exactly two fan-out points per context
  # (spec phase + impl phase bands). If a template grows a third
  # fan-out the layout has nowhere to put it, so fail loud rather
  # than silently truncate.
  defp phase_descendant_sets([], _topo), do: {MapSet.new(), MapSet.new()}

  defp phase_descendant_sets([first], topo) do
    {Topology.descendants_of([first], topo.edges), MapSet.new()}
  end

  defp phase_descendant_sets([first, second], topo) do
    first_set = Topology.descendants_of([first], topo.edges)
    second_set = Topology.descendants_of([second], topo.edges)
    {MapSet.difference(first_set, second_set), second_set}
  end

  defp phase_descendant_sets(fan_outs, _topo) do
    raise ArgumentError,
          "graph projector layout supports at most 2 fan-out points per context, got #{length(fan_outs)}"
  end

  defp max_phase_rows(children_with_reqs, key) do
    children_with_reqs |> Enum.map(&length(Map.fetch!(&1, key))) |> Enum.max(fn -> 0 end)
  end

  defp build_context_column(sorted_ctx_reqs, children_with_reqs, layout, actionable_set, size, topo) do
    {nodes, _y_cursor, specs_y, impl_y} =
      build_context_column_with_cursor(
        sorted_ctx_reqs, children_with_reqs, layout, actionable_set, size, &short_req_label/1, topo)

    {nodes, specs_y, impl_y}
  end

  defp build_context_column_with_cursor(sorted_ctx_reqs, children_with_reqs, layout, actionable_set, size, label_fn, topo) do
    child_count = length(children_with_reqs)
    max_spec = max_phase_rows(children_with_reqs, :spec_reqs)
    max_impl = max_phase_rows(children_with_reqs, :impl_reqs)

    # Phase-break indices come from structural fan-out: the parent
    # nodes that feed children-side branches. The FIRST fan-out is
    # the spec-phase break, the SECOND is the impl-phase break.
    fan_out_idxs =
      sorted_ctx_reqs
      |> Enum.with_index()
      |> Enum.filter(fn {req, _idx} -> MapSet.member?(topo.fan_out_keys, node_key(req)) end)
      |> Enum.map(fn {_req, idx} -> idx end)

    [specs_idx, impl_idx] = Enum.take(fan_out_idxs ++ [nil, nil], 2)

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
    tree_node_keys = MapSet.new(tree_nodes, &node_key/1)
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

  defp tree_layout_for_top_level(comp, parent_ids, components, comp_reqs_by_id, actionable_set, topo) do
    if MapSet.member?(parent_ids, comp.id) do
      layout_context_tree_nodes(comp, components, comp_reqs_by_id, actionable_set, topo)
    else
      layout_standalone_nodes(comp, comp_reqs_by_id, actionable_set, topo)
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
