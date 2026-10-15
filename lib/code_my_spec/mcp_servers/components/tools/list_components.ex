defmodule CodeMySpec.McpServers.Components.Tools.ListComponents do
  @moduledoc "Lists all components in a project"

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case components(frame) do
      {:ok, components} -> {:reply, ComponentsMapper.components_list_response(components), frame}
      {:error, atom} -> {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(_params, frame) do
    with {:ok, components} <- components(frame) do
      {:ok, Enum.map(components, &row/1)}
    end
  end

  defp components(frame) do
    with {:ok, scope} <- Validators.validate_scope(frame) do
      {:ok, Components.list_components(scope)}
    end
  end

  defp row(c) do
    %{
      "id" => c.id,
      "name" => c.name,
      "type" => c.type,
      "module_name" => c.module_name,
      "description" => c.description,
      "provenance" => c.provenance && to_string(c.provenance)
    }
  end
end
