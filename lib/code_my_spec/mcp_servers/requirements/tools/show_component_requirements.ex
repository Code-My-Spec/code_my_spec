defmodule CodeMySpec.McpServers.Requirements.Tools.ShowComponentRequirements do
  @moduledoc """
  Show all requirements for a specific component, identified by module name or ID.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements.RequirementGraph

  schema do
    field :component, :string, required: true, description: "Component module name (e.g. 'MyApp.Accounts') or component ID"
  end

  @impl true
  def execute(%{component: component_ref}, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        respond_with_component(scope, component_ref, frame)

      {:error, reason} ->
        {:reply, RequirementsMapper.error(reason), frame}
    end
  end

  defp respond_with_component(scope, component_ref, frame) do
    case resolve_component(scope, component_ref) do
      nil ->
        {:reply, RequirementsMapper.error("Component '#{component_ref}' not found"), frame}

      component ->
        nodes = RequirementGraph.compute_all(scope)
        reqs = Enum.filter(nodes, &(&1.entity_type == "component" and to_string(&1.entity_id) == component.id))

        {:reply, component_response(component, reqs), frame}
    end
  end

  defp resolve_component(scope, ref) do
    case UUID.info(ref) do
      {:ok, _} -> Components.get_component(scope, ref)
      _ -> Components.get_component_by_module_name(scope, ref)
    end
  end

  defp component_response(component, reqs) do
    satisfied = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)

    lines =
      Enum.map_join(reqs, "\n", fn r ->
        status = if r.satisfied, do: "[x]", else: "[ ]"
        "- #{status} **#{r.name}** — #{r.description || "no description"}"
      end)

    text = """
    # #{component.module_name}

    **Type:** #{component.type}
    **Requirements:** #{satisfied}/#{total} satisfied

    #{lines}
    """

    Response.tool()
    |> Response.text(String.trim(text))
  end
end
