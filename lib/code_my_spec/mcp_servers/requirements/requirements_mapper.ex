defmodule CodeMySpec.McpServers.Requirements.RequirementsMapper do
  @moduledoc """
  Maps requirements data to MCP responses using a hybrid format:
  human-readable markdown + JSON data for programmatic access.
  """

  alias Anubis.Server.Response

  def list_requirements_response(nodes) do
    grouped = group_by_entity(nodes)
    summary = format_grouped_summary(grouped)
    data = Enum.map(nodes, &node_data/1)

    hybrid_response(summary, %{requirements: data, count: length(nodes)})
  end

  @doc """
  Format next requirement response. Accepts either a persisted Requirement
  or a computed node map from RequirementGraph.
  """
  def next_requirement_response(%{entity_type: _} = node) do
    # Computed node from RequirementGraph
    task_module = node.satisfied_by
    task_name = task_module |> inspect() |> String.split(".") |> List.last()

    entity_line =
      case node.entity_type do
        "component" -> "**Component:** #{node.entity_name}\n"
        "story" -> "**Story:** #{node.entity_name}\n"
        _ -> ""
      end

    summary = """
    # Next Requirement: #{node.name}

    #{node.description}

    **Task:** `#{task_name}`
    **Execution:** #{execution_label(node.execution_type)}
    **Validation:** #{validation_label(node.validation_type)}
    #{entity_line}
    Call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}`.
    """

    Response.tool()
    |> Response.text(String.trim(summary))
  end

  def next_requirement_response(requirement) do
    # Legacy: persisted Requirement struct
    task_module = requirement.satisfied_by
    task_name = task_module |> inspect() |> String.split(".") |> List.last()

    component_name =
      case requirement.component do
        %{module_name: name} -> name
        _ -> nil
      end

    story_title =
      case requirement.story do
        %{title: title} -> title
        _ -> nil
      end

    component_line = if component_name, do: "**Component:** #{component_name}\n", else: ""
    story_line = if story_title, do: "**Story:** #{story_title}\n", else: ""

    summary = """
    # Next Requirement: #{requirement.name}

    #{requirement.description}

    **Task:** `#{task_name}`
    **Execution:** #{execution_label(requirement.execution_type)}
    **Validation:** #{validation_label(requirement.validation_type)}
    #{component_line}#{story_line}
    Call `start_task` with requirement_id `#{requirement.id}` to begin work.
    """

    Response.tool()
    |> Response.text(String.trim(summary))
  end

  def sync_required_response do
    Response.tool()
    |> Response.text(
      "# Project Needs Sync\n\nThe project is linked but has no requirements yet.\n\nCall `sync_project` to sync components and requirements, then `get_next_requirement` again."
    )
  end

  def all_satisfied_response do
    Response.tool()
    |> Response.text("# All requirements satisfied\n\nNo actionable requirements remain.")
    |> Map.put(:structured_content, %{status: :complete})
  end

  def init_required_response(prompt) do
    Response.tool()
    |> Response.text(prompt <> "\n\nWhen all steps are complete, call `get_next_requirement` again.")
  end

  def error(reason) when is_atom(reason), do: reason |> to_string() |> error()

  def error(reason) when is_binary(reason) do
    Response.tool()
    |> Response.error(reason)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp node_data(node) do
    %{
      requirement_name: node.name,
      description: node.description,
      satisfied: node.satisfied,
      execution_type: node.execution_type,
      validation_type: node.validation_type,
      entity_type: node.entity_type,
      entity_id: node.entity_id,
      entity_name: node.entity_name,
      satisfied_by:
        if node.satisfied_by do
          node.satisfied_by |> inspect() |> String.split(".") |> List.last()
        end
    }
  end

  defp group_by_entity(nodes) do
    Enum.group_by(nodes, fn node ->
      {String.to_existing_atom(node.entity_type), node.entity_name}
    end)
  end

  defp format_grouped_summary(grouped) do
    sections =
      grouped
      |> Enum.sort_by(fn {{type, _}, _} ->
        case type do
          :project -> 0
          :story -> 1
          :component -> 2
          _ -> 3
        end
      end)
      |> Enum.map_join("\n\n", fn {{type, name}, nodes} ->
        label = entity_label(type, name)
        items = Enum.map_join(nodes, "\n", &format_node_line/1)
        "## #{label}\n\n#{items}"
      end)

    "# Project Requirements\n\n#{sections}"
  end

  defp entity_label(:project, _), do: "Project"
  defp entity_label(:story, name), do: "Story: #{name}"
  defp entity_label(:component, name), do: "Component: #{name}"
  defp entity_label(_, _), do: "Other"

  defp format_node_line(node) do
    status = if node.satisfied, do: "[x]", else: "[ ]"
    "- #{status} **#{node.name}** — #{node.description || "no description"}"
  end

  defp hybrid_response(summary, data) do
    Response.tool()
    |> Response.text(summary)
    |> Map.put(:structured_content, data)
  end

  defp execution_label(:sub_agent), do: "Delegate to a sub-agent"
  defp execution_label(_), do: "You are the agent responsible"

  defp validation_label(:manual), do: "Manual — use `evaluate_task` when done"
  defp validation_label(:automatic), do: "Automatic — the stop hook will evaluate"
  defp validation_label(_), do: "Unknown"
end
