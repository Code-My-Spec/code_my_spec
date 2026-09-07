defmodule CodeMySpec.McpServers.Architecture.Tools.ShowArchitectureOverview do
  @moduledoc """
  Returns the component overview organized by context.

  Shows all components grouped by parent context with types, descriptions,
  and dependency listings.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        components = Components.list_components_with_dependencies(scope)
        overview = Architecture.generate_overview(components)

        {:reply, text_response(overview), frame}

      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp text_response(content) do
    Response.tool()
    |> Response.text(content)
  end
end
