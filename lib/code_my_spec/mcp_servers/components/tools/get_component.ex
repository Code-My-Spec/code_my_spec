defmodule CodeMySpec.McpServers.Components.Tools.GetComponent do
  @moduledoc "Gets a single component by ID"

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :component_id, :string, required: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         component when not is_nil(component) <-
           Components.get_component(scope, params.component_id) do
      {:reply, ComponentsMapper.component_response(component), frame}
    else
      nil ->
        {:reply, ComponentsMapper.error("Component not found"), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end
end
