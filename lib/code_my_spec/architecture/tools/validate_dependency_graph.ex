defmodule CodeMySpec.Architecture.Tools.ValidateDependencyGraph do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Architecture.Tools.Responses, as: ArchitectureMapper

  @impl true
  def name, do: "validate_dependency_graph"

  @impl true
  def description do
    """
    Validates the component dependency graph for circular dependencies.

    Returns validation result indicating success or detailed list of detected cycles.
    Circular dependencies violate clean architecture principles and make code
    harder to test and maintain.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        result = Components.validate_dependency_graph(scope)

        ArchitectureMapper.validation_result_response(result)

      {:error, reason} ->
        ArchitectureMapper.error(reason)
    end
  end
end
