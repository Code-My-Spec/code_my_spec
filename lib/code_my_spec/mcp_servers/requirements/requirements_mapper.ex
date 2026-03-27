defmodule CodeMySpec.McpServers.Requirements.RequirementsMapper do
  @moduledoc """
  Maps requirements data to MCP responses using a hybrid format:
  human-readable markdown + JSON data for programmatic access.
  """

  alias Anubis.Server.Response

  def list_requirements_response(requirements) do
    grouped = group_by_entity(requirements)
    summary = format_grouped_summary(grouped)
    data = Enum.map(requirements, &requirement_data/1)

    hybrid_response(summary, %{requirements: data, count: length(requirements)})
  end

  def next_requirement_response(requirement) do
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

    summary = """
    # Next Requirement: #{requirement.name}

    #{requirement.description}

    **Task:** `#{task_name}`
    **Execution:** #{execution_label(requirement.execution_type)}
    **Validation:** #{validation_label(requirement.validation_type)}
    #{if component_name, do: "**Component:** #{component_name}", else: ""}
    #{if story_title, do: "**Story:** #{story_title}", else: ""}

    Call `start_task` with requirement_id to begin work.
    """

    data = requirement_data(requirement)

    hybrid_response(String.trim(summary), data)
  end

  def all_satisfied_response do
    Response.tool()
    |> Response.text("# All requirements satisfied\n\nNo actionable requirements remain.")
    |> Map.put(:structured_content, %{status: :complete})
  end

  def init_required_response(prompt) do
    Response.tool()
    |> Response.text(prompt)
    |> Map.put(:structured_content, %{status: :init_required})
  end

  def error(reason) when is_atom(reason), do: reason |> to_string() |> error()

  def error(reason) when is_binary(reason) do
    Response.tool()
    |> Response.error(reason)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp requirement_data(req) do
    %{
      requirement_id: req.id,
      requirement_name: req.name,
      description: req.description,
      satisfied: req.satisfied,
      artifact_type: req.artifact_type,
      execution_type: req.execution_type,
      validation_type: req.validation_type,
      component_id: req.component_id,
      component_module_name:
        case req.component do
          %{module_name: name} -> name
          _ -> nil
        end,
      story_id: req.story_id,
      story_title:
        case req.story do
          %{title: title} -> title
          _ -> nil
        end,
      project_id: req.project_id,
      satisfied_by:
        if req.satisfied_by do
          req.satisfied_by |> inspect() |> String.split(".") |> List.last()
        end
    }
  end

  defp group_by_entity(requirements) do
    requirements
    |> Enum.group_by(fn req ->
      cond do
        req.component_id -> {:component, req.component}
        req.story_id -> {:story, req.story}
        req.project_id -> {:project, req.project}
        true -> {:unknown, nil}
      end
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
      |> Enum.map_join("\n\n", fn {{type, entity}, reqs} ->
        label = entity_label(type, entity)
        items = Enum.map_join(reqs, "\n", &format_requirement_line/1)
        "## #{label}\n\n#{items}"
      end)

    "# Project Requirements\n\n#{sections}"
  end

  defp entity_label(:project, _), do: "Project"

  defp entity_label(:story, %{title: title}), do: "Story: #{title}"
  defp entity_label(:story, _), do: "Story"

  defp entity_label(:component, %{module_name: name}), do: "Component: #{name}"
  defp entity_label(:component, _), do: "Component"

  defp entity_label(_, _), do: "Other"

  defp format_requirement_line(req) do
    status = if req.satisfied, do: "[x]", else: "[ ]"
    "- #{status} **#{req.name}** — #{req.description || "no description"}"
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
