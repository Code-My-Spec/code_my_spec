defmodule CodeMySpec.Components.Tools.GetComponent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component, as: Record
  alias CodeMySpec.Components.Dependency
  alias CodeMySpec.Files
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "get_component"

  @impl true
  def description do
    """
    One component as its record describes it: type, description, provenance,
    parent, what it depends on (each marked planned and/or in code) and the
    files that belong to it. By id or by module name. Components are records
    (3aeb66cf); this is how an agent reads one without listing the whole
    architecture.
    """
  end

  @impl true
  def params do
    %{
      module_name: {:meta, :string, [description: "Or its module name, e.g. MyApp.Accounts."]},
      component_id: {:meta, :string, [description: "The component's id."]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         %Record{} = component <- find(scope, params) do
      response(scope, component)
    else
      nil ->
        ComponentsMapper.error("Component not found")

      {:error, reason} ->
        ComponentsMapper.error(reason)
    end
  end

  defp find(scope, %{component_id: id}) when is_binary(id),
    do: Components.get_component(scope, id)

  defp find(scope, %{module_name: name}) when is_binary(name),
    do: Components.get_component_by_module_name(scope, name)

  defp find(_scope, _params), do: {:error, "give component_id or module_name"}

  defp response(scope, component) do
    parent =
      component.parent_component_id &&
        Components.get_component(scope, component.parent_component_id)

    {:ok,
     JSON.encode!(%{
       id: component.id,
       name: component.name,
       type: component.type,
       module_name: component.module_name,
       description: component.description,
       provenance: component.provenance,
       parent_component_id: component.parent_component_id,
       parent: parent && parent.module_name,
       dependencies:
         scope
         |> Components.list_component_dependencies(component.id)
         |> Enum.map(&dependency/1)
         |> Enum.sort_by(& &1.module_name),
       files:
         scope
         |> Files.list_component_files(component.id)
         |> Enum.map(& &1.path)
         |> Enum.uniq()
         |> Enum.sort()
     })}
  end

  # Planned: an architect authored the edge. In code: the last sync saw a call.
  defp dependency(%Dependency{} = dep),
    do: %{
      module_name: dep.target_component.module_name,
      planned: dep.provenance == :authored,
      in_code: dep.in_code
    }
end
