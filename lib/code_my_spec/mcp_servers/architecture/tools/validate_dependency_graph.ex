defmodule CodeMySpec.McpServers.Architecture.Tools.ValidateDependencyGraph do
  @moduledoc """
  Validates the component dependency graph for circular dependencies.

  Returns validation result indicating success or detailed list of detected cycles.
  Circular dependencies violate clean architecture principles and make code
  harder to test and maintain.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      result = Components.validate_dependency_graph(scope)

      {:reply, ArchitectureMapper.validation_result_response(result), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end
end
