defmodule CodeMySpec.McpServers.Requirements.Tools.ShowRequirement do
  @moduledoc """
  Show a single requirement by name with full details including satisfaction
  status, task module, and entity context.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements.RequirementGraph

  schema do
    field :name, :string, required: true, description: "The requirement name (e.g. 'spec_written', 'tests_written')"
    field :entity_type, :string, description: "Entity type filter: 'component', 'story', or 'project'"
    field :entity_id, :string, description: "Entity ID to scope the requirement lookup"
  end

  @impl true
  def execute(%{name: name} = params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        respond_with_matches(scope, name, params, frame)

      {:error, reason} ->
        {:reply, RequirementsMapper.error(reason), frame}
    end
  end

  defp respond_with_matches(scope, name, params, frame) do
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)

    matches =
      nodes
      |> Enum.filter(&(&1.name == name))
      |> maybe_filter_entity(params)

    case matches do
      [] -> {:reply, RequirementsMapper.error("Requirement '#{name}' not found"), frame}
      [single] -> {:reply, detail_response(single), frame}
      multiple -> {:reply, list_response(name, multiple), frame}
    end
  end

  defp maybe_filter_entity(nodes, %{entity_type: type, entity_id: id}) do
    Enum.filter(nodes, fn n -> n.entity_type == type and to_string(n.entity_id) == id end)
  end

  defp maybe_filter_entity(nodes, _), do: nodes

  defp detail_response(node) do
    text = """
    # #{node.name}

    #{node.description || "No description"}

    **Status:** #{if node.satisfied, do: "Satisfied", else: "Not satisfied"}
    **Entity:** #{String.capitalize(node.entity_type)}: #{node.entity_name}
    **Execution:** #{execution_label(node.execution_type)}
    **Validation:** #{validation_label(node.validation_type)}
    """

    Response.tool()
    |> Response.text(String.trim(text))
  end

  defp list_response(name, nodes) do
    lines =
      Enum.map_join(nodes, "\n", fn n ->
        status = if n.satisfied, do: "[x]", else: "[ ]"
        "- #{status} #{String.capitalize(n.entity_type)}: #{n.entity_name}"
      end)

    text = "# #{name} (#{length(nodes)} instances)\n\n#{lines}"

    Response.tool()
    |> Response.text(String.trim(text))
  end

  defp execution_label(:sub_agent), do: "Delegate to a sub-agent"
  defp execution_label(_), do: "You are the agent responsible"

  defp validation_label(:manual), do: "Manual — use `evaluate_task` when done"
  defp validation_label(:automatic), do: "Automatic — the stop hook will evaluate"
  defp validation_label(_), do: "Unknown"
end
