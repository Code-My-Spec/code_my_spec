defmodule CodeMySpec.McpServers.Components.Tools.DeleteDependency do
  @moduledoc "Deletes a dependency relationship between components"

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :id, :string, required: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         dependency <- Components.get_dependency!(scope, params.id),
         {:ok, dependency} <- Components.delete_dependency(scope, dependency) do
      {:reply, dependency_response(dependency), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, ComponentsMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  defp dependency_response(dependency) do
    alias Anubis.Server.Response

    Response.tool()
    |> Response.json(%{
      id: dependency.id,
      source_component: component_summary(dependency.source_component),
      target_component: component_summary(dependency.target_component),
      deleted: true
    })
  end

  defp component_summary(component) do
    %{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name
    }
  end
end
