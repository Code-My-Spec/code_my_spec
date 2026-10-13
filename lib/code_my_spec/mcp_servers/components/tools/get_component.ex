defmodule CodeMySpec.McpServers.Components.Tools.GetComponent do
  @moduledoc """
  One component as its record describes it: type, description, provenance,
  parent, what it depends on (each marked planned and/or in code) and the
  files that belong to it. By id or by module name. Components are records
  (3aeb66cf); this is how an agent reads one without listing the whole
  architecture.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component, as: Record
  alias CodeMySpec.Components.Dependency
  alias CodeMySpec.Files
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :component_id, :string, description: "The component's id."
    field :module_name, :string, description: "Or its module name, e.g. MyApp.Accounts."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         %Record{} = component <- find(scope, params) do
      {:reply, response(scope, component), frame}
    else
      nil ->
        {:reply, ComponentsMapper.error("Component not found"), frame}

      {:error, reason} ->
        {:reply, ComponentsMapper.error(reason), frame}
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

    Response.tool()
    |> Response.json(%{
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
    })
  end

  # Planned: an architect authored the edge. In code: the last sync saw a call.
  defp dependency(%Dependency{} = dep),
    do: %{
      module_name: dep.target_component.module_name,
      planned: dep.provenance == :authored,
      in_code: dep.in_code
    }
end
