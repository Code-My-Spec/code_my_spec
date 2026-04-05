defmodule CodeMySpec.McpServers.Architecture.Tools.ShowArchitectureOverview do
  @moduledoc """
  Returns the component overview organized by context.

  Shows all components grouped by parent context with types, descriptions,
  and dependency listings.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      components = Components.list_components_with_dependencies(scope)
      overview = Architecture.generate_overview(components)

      {:reply, text_response(overview), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp text_response(content) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.text(content)
  end
end
