defmodule CodeMySpec.McpServers.Components.Tools.ListComponents do
  @moduledoc "Lists all components in a project"

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_scope(frame) do
      {:ok, scope} ->
        components = Components.list_components(scope)
        {:reply, ComponentsMapper.components_list_response(components), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end
end
