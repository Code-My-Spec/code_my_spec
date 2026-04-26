defmodule CodeMySpec.McpServers.Components.Tools.OrphanedContexts do
  @moduledoc "Lists all contexts with no user story and no dependencies"

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
        orphaned_contexts = Components.list_orphaned_contexts(scope)
        {:reply, ComponentsMapper.components_list_response(orphaned_contexts), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end
end
