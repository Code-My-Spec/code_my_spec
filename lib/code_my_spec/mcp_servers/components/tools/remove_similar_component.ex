defmodule CodeMySpec.McpServers.Components.Tools.RemoveSimilarComponent do
  @moduledoc "Removes a similar component relationship"

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :component_id, :integer, required: true
    field :similar_component_id, :integer, required: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         component <- Components.get_component!(scope, params.component_id),
         similar_component <- Components.get_component!(scope, params.similar_component_id),
         {:ok, _similar_component_record} <-
           Components.remove_similar_component(scope, component, similar_component) do
      {:reply, similar_component_response(component, similar_component), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, ComponentsMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  defp similar_component_response(component, similar_component) do
    alias Anubis.Server.Response

    Response.tool()
    |> Response.json(%{
      component: component_summary(component),
      similar_component: component_summary(similar_component),
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
