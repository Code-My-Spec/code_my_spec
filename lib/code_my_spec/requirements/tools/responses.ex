defmodule CodeMySpec.Requirements.Tools.Responses do
  @moduledoc """
  Maps requirements data to MCP tool responses.
  """

  alias CodeMySpec.Requirements.Directives

  # ---------------------------------------------------------------------------
  # Public — response builders
  # ---------------------------------------------------------------------------

  def story_execution_response(execution, active_subagents \\ %{}) do
    execution |> Directives.format_story_execution(active_subagents) |> tool_text()
  end

  def next_requirements_response(nodes, active_subagents \\ %{}) do
    nodes
    |> Directives.format_next_requirements(active_subagents)
    |> tool_text()
  end

  def list_requirements_response(nodes, meta \\ []) do
    total = Keyword.get(meta, :total, length(nodes))
    shown = length(nodes)

    body =
      nodes
      |> group_by_entity()
      |> format_grouped_summary()

    header =
      if total > shown do
        "# Project Requirements (showing #{shown} of #{total})\n\n_Use filters (`requirement_name`, `entity_type`, `module_filter`) or raise `limit` to see more._\n\n"
      else
        "# Project Requirements (#{total})\n\n"
      end

    tool_text(header <> body)
  end

  def requirements_summary_response(nodes, opts) do
    total = length(nodes)
    filters = format_active_filters(opts)
    diagnostic? = Map.get(opts, :diagnostic, false)

    by_name =
      nodes
      |> Enum.group_by(& &1.name)
      |> Enum.sort_by(fn {_name, group} -> -length(group) end)

    body =
      case by_name do
        [] ->
          "_No requirements match the current filter._"

        groups ->
          rows = Enum.map_join(groups, "\n", &format_summary_row(&1, diagnostic?))

          footer =
            if diagnostic? do
              "_Total: #{total}. All unsatisfied counts are local-check failures — " <>
                "satisfaction is local truth, prerequisites govern actionability separately " <>
                "(see `get_next_requirement`)._"
            else
              "_Total: #{total}. Drill in with `requirement_name: \"<name>\"`, `entity_type`, " <>
                "or `module_filter`. Set `summary: false` for per-entity rows._"
            end

          "#{rows}\n\n#{footer}"
      end

    tool_text("# Requirements Summary#{filters}\n\n#{body}")
  end

  defp format_summary_row({name, group}, true) do
    locally_failing = Enum.count(group, &(not &1.satisfied))
    "- **#{name}**: #{length(group)} (#{locally_failing} locally failing)"
  end

  defp format_summary_row({name, group}, false), do: "- **#{name}**: #{length(group)}"

  # Names what was counted when no status filter was given, because the counts
  # alone read as friction and are not.
  #
  # Unfiltered, `implementation_file: 900` on this project is 900 *satisfied*
  # requirements. A reader who takes that as work outstanding goes looking for a
  # break that does not exist — which happened, off a moduledoc that described
  # the default as a summary of unsatisfied requirements. With
  # `status: "unsatisfied"` the same project totals 55.
  #
  # Only when the filter is absent: with it, `format_active_filters/1` already
  # says `status=…` and a second label would be noise.
  defp format_active_filters(%{status: nil} = opts) do
    named_filters(opts) <> " — all statuses; add `status: \"unsatisfied\"` for outstanding work"
  end

  defp format_active_filters(opts), do: named_filters(opts)

  defp named_filters(opts) do
    parts =
      [
        {"status", opts.status},
        {"entity_type", opts.entity_type},
        {"requirement_name", opts.requirement_name},
        {"module_filter", opts.module_filter}
      ]
      |> Enum.reject(fn {_k, v} -> v == nil end)
      |> Enum.map(fn {k, v} -> "#{k}=`#{v}`" end)

    case parts do
      [] -> ""
      _ -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  def sync_required_response do
    tool_text("""
    # Project Needs Sync

    The project is linked but has no requirements yet.

    Call `sync_project` to sync components and requirements, then `get_next_requirement` again.\
    """)
  end

  def all_satisfied_response do
    {:ok, "# All requirements satisfied\n\nNo actionable requirements remain."}
  end

  def init_required_response(prompt) do
    tool_text(prompt <> "\n\nWhen all steps are complete, call `get_next_requirement` again.")
  end

  def error(reason) when is_atom(reason), do: reason |> to_string() |> error()
  def error(reason) when is_binary(reason), do: {:error, reason}

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
  defp entity_label(:issue, name), do: "Issue: #{name}"
  defp entity_label(_, _), do: "Other"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tool_text(text), do: {:ok, text}
end
