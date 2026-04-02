defmodule CodeMySpec.Requirements.GraphProjector do
  @moduledoc """
  Projects the computed requirement graph into a JSON structure for sigma.js.

  Top-down flow:
  1. Early project chain (setup → strategy → architecture → issues)
  2. Stories fan out from issues_resolved, each showing its requirement chain
  3. Story terminal nodes merge into qa_preflight
  4. Late project chain (bdd specs → journey)
  """

  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Users.Scope

  @story_fan_in "qa_preflight"
  @story_fan_out "issues_resolved"

  @colors %{
    satisfied: "#60a5fa",
    actionable: "#4ade80",
    blocked: "#fbbf24"
  }

  @row_gap 500
  @col_gap 700
  @story_row_gap 350

  @spec project_graph(Scope.t()) :: map()
  def project_graph(%Scope{} = scope) do
    %{nodes: nodes} = Requirements.project_graph(scope)
    actionable = Requirements.next_actionable_project(scope)

    actionable_set =
      MapSet.new(actionable, fn n -> {n.entity_type, n.entity_id, n.name} end)

    project_nodes = Enum.filter(nodes, &(&1.entity_type == "project"))
    story_nodes = Enum.filter(nodes, &(&1.entity_type == "story"))

    build_graph(project_nodes, story_nodes, actionable_set)
  end

  defp build_graph(project_nodes, story_nodes, actionable_set) do
    def_order = definition_order()
    sorted_project = Enum.sort_by(project_nodes, fn n -> Map.get(def_order, n.name, 999) end)

    fan_in_idx = Enum.find_index(sorted_project, &(&1.name == @story_fan_in)) || 0
    {early, late} = Enum.split(sorted_project, fan_in_idx)

    # Group story nodes by story, preserving requirement definition order
    story_def_order = story_definition_order()
    stories_by_id = Enum.group_by(story_nodes, & &1.entity_id)

    story_groups =
      Enum.map(stories_by_id, fn {_id, reqs} ->
        sorted = Enum.sort_by(reqs, fn r -> Map.get(story_def_order, r.name, 999) end)
        %{title: hd(sorted).entity_name, entity_id: hd(sorted).entity_id, reqs: sorted}
      end)

    # --- Layout ---

    # Early project nodes: vertical chain at x=0
    early_sigma =
      early
      |> Enum.with_index()
      |> Enum.map(fn {n, idx} ->
        sigma_node(n.name, label(n), 0, -(idx * @row_gap), 20, cls(n, actionable_set),
          entity_type: "project", name: n.name)
      end)

    # Story columns start below the early chain
    story_start_y = -(length(early) * @row_gap)
    story_count = length(story_groups)
    story_reqs_count = length(RequirementDefinitionData.story_requirements())

    # Each story is a column, with a title node + requirement nodes flowing down
    {story_sigma, story_edges, story_first_keys, story_last_keys} =
      story_groups
      |> Enum.with_index()
      |> Enum.reduce({[], [], [], []}, fn {group, col_idx}, {nodes_acc, edges_acc, firsts, lasts} ->
        x = (col_idx - (story_count - 1) / 2) * @col_gap

        # Title node
        title_key = "st_#{sanitize_id(group.entity_id)}"
        title_node = sigma_node(title_key, short_title(group.title), x,
          story_start_y, 18, :title,
          entity_type: "story", entity_id: group.entity_id)

        # Requirement nodes below title
        {req_nodes, req_edges, _} =
          group.reqs
          |> Enum.with_index()
          |> Enum.reduce({[], [], nil}, fn {req, req_idx}, {rnodes, redges, prev_key} ->
            key = "#{sanitize_id(group.entity_id)}_#{req.name}"
            y = story_start_y - ((req_idx + 1) * @story_row_gap)
            node = sigma_node(key, req_label(req), x, y, 12, cls(req, actionable_set),
              entity_type: "story", entity_id: group.entity_id, name: req.name)

            # Edge from previous req (or from title)
            source = prev_key || title_key
            e = edge("#{source}->#{key}", source, key)

            {rnodes ++ [node], redges ++ [e], key}
          end)

        last_key = List.last(Enum.map(group.reqs, fn r -> "#{sanitize_id(group.entity_id)}_#{r.name}" end))

        {
          nodes_acc ++ [title_node | req_nodes],
          edges_acc ++ req_edges,
          firsts ++ [title_key],
          lasts ++ [last_key]
        }
      end)

    # Late project nodes: below the story columns
    late_start_y = story_start_y - ((story_reqs_count + 1) * @story_row_gap) - @row_gap

    late_sigma =
      late
      |> Enum.with_index()
      |> Enum.map(fn {n, idx} ->
        sigma_node(n.name, label(n), 0, late_start_y - (idx * @row_gap), 20, cls(n, actionable_set),
          entity_type: "project", name: n.name)
      end)

    # --- Edges ---

    # Project prerequisite edges
    project_edges =
      Enum.flat_map(sorted_project, fn n ->
        Enum.map(n.prerequisites, fn prereq ->
          edge("#{prereq}->#{n.name}", prereq, n.name)
        end)
      end)

    # Fan-out: issues_resolved → each story title
    fan_out_edges =
      Enum.map(story_first_keys, fn key ->
        edge("#{@story_fan_out}->#{key}", @story_fan_out, key)
      end)

    # Fan-in: each story's last req → qa_preflight
    fan_in_edges =
      Enum.map(story_last_keys, fn key ->
        edge("#{key}->#{@story_fan_in}", key, @story_fan_in)
      end)

    %{
      nodes: early_sigma ++ story_sigma ++ late_sigma,
      edges: project_edges ++ story_edges ++ fan_out_edges ++ fan_in_edges
    }
  end

  defp sigma_node(key, label, x, y, size, status, extra) do
    %{
      key: key,
      attributes:
        Map.merge(
          %{label: label, x: x, y: y, size: size, color: color(status), type: "circle"},
          Map.new(extra)
        )
    }
  end

  defp edge(key, source, target) do
    %{key: key, source: source, target: target,
      attributes: %{size: 2, color: "#64748b", type: "arrow"}}
  end

  defp sanitize_id(id) when is_integer(id), do: "#{id}"
  defp sanitize_id(id) when is_binary(id), do: String.replace(id, "-", "")

  defp label(n) do
    name = n.name |> String.replace("_", " ")
    if n.satisfied, do: "#{name} ✓", else: name
  end

  defp req_label(n) do
    short = n.name |> String.replace("_", " ")
    if n.satisfied, do: "#{short} ✓", else: short
  end

  defp short_title(title) do
    if String.length(title) > 35, do: String.slice(title, 0, 35) <> "..", else: title
  end

  defp cls(%{satisfied: true}, _), do: :satisfied
  defp cls(n, actionable_set) do
    key = {n.entity_type, n.entity_id, n.name}
    if MapSet.member?(actionable_set, key), do: :actionable, else: :blocked
  end

  defp color(:title), do: "#94a3b8"
  defp color(status), do: Map.get(@colors, status, @colors.blocked)

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
