defmodule CodeMySpec.McpServers.Components.Tools.RemoveDependency do
  @moduledoc """
  Removes one component's dependency on another. The other half of
  `AddDependency`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :source_component_id, :string,
      required: true,
      description: "The component that depends on the other"

    field :target_component_id, :string,
      required: true,
      description: "The component it should no longer depend on"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         %{} = dependency <-
           Components.get_dependency_between(
             scope,
             params.source_component_id,
             params.target_component_id
           ),
         {:ok, _removed} <- Components.delete_dependency(scope, dependency) do
      {:reply,
       Response.tool()
       |> Response.text(
         "`#{dependency.source_component.module_name}` no longer depends on " <>
           "`#{dependency.target_component.module_name}`."
       ), frame}
    else
      nil ->
        {:reply, ComponentsMapper.error("No such dependency in this project."), frame}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, ComponentsMapper.validation_error(changeset), frame}
    end
  end
end
