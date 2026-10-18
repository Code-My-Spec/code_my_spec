defmodule CodeMySpec.Requirements.Tools.ShowComponentRequirements do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Requirements.Tools.Responses, as: RequirementsMapper
  alias CodeMySpec.Requirements.RequirementGraph

  @impl true
  def name, do: "show_component_requirements"

  @impl true
  def description do
    """
    Show all requirements for a specific component, identified by module name or ID.
    """
  end

  @impl true
  def params do
    %{
      component:
        {:required,
         {:meta, :string,
          [description: "Component module name (e.g. 'MyApp.Accounts') or component ID"]}}
    }
  end

  @impl true
  def call(%{component: component_ref}, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        respond_with_component(scope, component_ref, context)

      {:error, reason} ->
        RequirementsMapper.error(reason)
    end
  end

  defp respond_with_component(scope, component_ref, _context) do
    case resolve_component(scope, component_ref) do
      nil ->
        RequirementsMapper.error("Component '#{component_ref}' not found")

      component ->
        {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)

        reqs =
          Enum.filter(
            nodes,
            &(&1.entity_type == "component" and to_string(&1.entity_id) == component.id)
          )

        component_response(component, reqs)
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

    {:ok, String.trim(text)}
  end
end
