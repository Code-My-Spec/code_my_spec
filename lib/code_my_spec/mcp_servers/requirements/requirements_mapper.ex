defmodule CodeMySpec.McpServers.Requirements.RequirementsMapper do
  @moduledoc """
  Maps requirements data to MCP tool responses.
  """

  alias Anubis.Server.Response

  # ---------------------------------------------------------------------------
  # Public — response builders
  # ---------------------------------------------------------------------------

  def next_requirements_response(nodes) do
    nodes
    |> format_next_requirements()
    |> tool_text()
  end

  def format_next_requirements(nodes) do
    {orchestrated, standalone} = Enum.split_with(nodes, & &1.orchestrated_by)

    # Only show the first (highest-priority) orchestration group,
    # scoped to a specific parent entity (e.g., one context at a time).
    orchestrated_section =
      case orchestrated do
        [] ->
          ""

        [first | _] ->
          key = {first.orchestrated_by, first.parent_entity_id}

          group_nodes =
            Enum.filter(orchestrated, &({&1.orchestrated_by, &1.parent_entity_id} == key))

          orchestrator = first.orchestrated_by
          parent_name = first.parent_entity_name || "unknown"
          header = orchestration_prompt(orchestrator)
          inner = format_satisfied_by_groups(group_nodes)

          "## #{parent_name}\n\n#{header}\n\n#{inner}"
      end

    # When an orchestration group is active, focus on it — don't show
    # unrelated standalone items that distract from the current context.
    standalone_sections =
      if orchestrated_section == "" do
        format_satisfied_by_groups(standalone)
      else
        ""
      end

    [orchestrated_section, standalone_sections]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  def list_requirements_response(nodes) do
    summary =
      nodes
      |> group_by_entity()
      |> format_grouped_summary()

    tool_text("# Project Requirements\n\n#{summary}")
  end

  def sync_required_response do
    tool_text("""
    # Project Needs Sync

    The project is linked but has no requirements yet.

    Call `sync_project` to sync components and requirements, then `get_next_requirement` again.\
    """)
  end

  def all_satisfied_response do
    Response.tool()
    |> Response.text("# All requirements satisfied\n\nNo actionable requirements remain.")
  end

  def init_required_response(prompt) do
    tool_text(prompt <> "\n\nWhen all steps are complete, call `get_next_requirement` again.")
  end

  def error(reason) when is_atom(reason), do: reason |> to_string() |> error()
  def error(reason) when is_binary(reason), do: Response.tool() |> Response.error(reason)

  # ---------------------------------------------------------------------------
  # Actionable requirements — grouped by task module
  # ---------------------------------------------------------------------------

  defp format_satisfied_by_groups(nodes) do
    nodes
    |> group_by_preserving_order(& &1.satisfied_by)
    |> Enum.map_join("\n\n", fn {mod, group_nodes} ->
      name = short_module_name(mod)
      items = Enum.map_join(group_nodes, "\n", &orchestrate_node/1)

      "### #{name}\n\n#{items}"
    end)
  end

  # Like Enum.group_by/2, but yields a list (not a map) ordered by the
  # position of each key's first occurrence in the input. Preserves
  # priority ordering from `next_actionable` — critical for rule 6
  # (story-linked components appear before unlinked ones).
  defp group_by_preserving_order(items, key_fn) do
    items
    |> Enum.reduce({[], %{}}, fn item, {keys, groups} ->
      key = key_fn.(item)

      if Map.has_key?(groups, key) do
        {keys, Map.update!(groups, key, &(&1 ++ [item]))}
      else
        {keys ++ [key], Map.put(groups, key, [item])}
      end
    end)
    |> then(fn {keys, groups} -> Enum.map(keys, &{&1, groups[&1]}) end)
  end

  defp orchestration_prompt(:develop_context) do
    """
    You are developing a bounded context.
    Implement the child components in dependency order.
    Develop schemas first, then fixtures and tests (if required), then code.
    """
  end

  defp orchestration_prompt(:develop_live_context) do
    "Develop Live Context — implement child LiveViews and LiveComponents"
  end

  defp orchestration_prompt(:develop_controller) do
    "Develop Controller — implement controller actions and views"
  end

  defp orchestration_prompt(other) do
    "#{other}"
  end

  defp orchestrate_node(node) do
    body = resolve_body(node)
    render_directive(node, body)
  end

  defp resolve_body(%{satisfied_by: mod} = node) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :orchestrate, 1) do
      unwrap_body(mod.orchestrate(node), node)
    else
      fallback_body(node)
    end
  end

  defp unwrap_body({:ok, text}, _node) when is_binary(text), do: text
  defp unwrap_body({:error, _reason}, node), do: fallback_body(node)
  defp unwrap_body(text, _node) when is_binary(text), do: text

  defp fallback_body(node), do: node.description || to_string(node.name)

  # Sub-agent tasks: include identifiers as parenthetical metadata so the
  # main agent can pass them to the sub-agent verbatim — but never as an
  # imperative "— call start_task" footer, which would mislead the main
  # agent into calling start_task directly and bypassing the sub-agent.
  defp render_directive(%{execution_type: :sub_agent} = node, body) do
    "- #{body} (sub-agent start_task args: #{sig(node)})"
  end

  defp render_directive(node, body) do
    if String.contains?(body, "requirement_name") do
      "- #{body}"
    else
      "- #{body} — call `start_task` with #{sig(node)}."
    end
  end

  defp sig(node) do
    "requirement_name=`#{node.name}`, entity_type=`#{node.entity_type}`, entity_id=`#{node.entity_id}`"
  end

  # ---------------------------------------------------------------------------
  # List requirements — grouped by entity
  # ---------------------------------------------------------------------------

  defp format_grouped_summary(grouped) do
    grouped
    |> Enum.sort_by(fn {{type, _}, _} -> entity_sort_key(type) end)
    |> Enum.map_join("\n\n", fn {{type, name}, nodes} ->
      items = Enum.map_join(nodes, "\n", &format_node_line/1)
      "## #{entity_label(type, name)}\n\n#{items}"
    end)
  end

  defp group_by_entity(nodes) do
    Enum.group_by(nodes, fn node ->
      {String.to_existing_atom(node.entity_type), node.entity_name}
    end)
  end

  defp format_node_line(%{satisfied: true} = node) do
    "- [x] **#{node.name}** — #{node.description || "no description"}"
  end

  defp format_node_line(node) do
    "- [ ] **#{node.name}** — #{node.description || "no description"}"
  end

  defp entity_sort_key(:project), do: 0
  defp entity_sort_key(:story), do: 1
  defp entity_sort_key(:component), do: 2
  defp entity_sort_key(_), do: 3

  defp entity_label(:project, _), do: "Project"
  defp entity_label(:story, name), do: "Story: #{name}"
  defp entity_label(:component, name), do: "Component: #{name}"
  defp entity_label(_, _), do: "Other"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tool_text(text), do: Response.tool() |> Response.text(text)

  defp short_module_name(mod), do: mod |> inspect() |> String.split(".") |> List.last()
end
