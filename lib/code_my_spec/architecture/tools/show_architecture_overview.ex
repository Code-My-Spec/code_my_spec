defmodule CodeMySpec.Architecture.Tools.ShowArchitectureOverview do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.Architecture.Tools.Responses, as: ArchitectureMapper

  @impl true
  def name, do: "show_architecture_overview"

  @impl true
  def description do
    """
    Returns the component overview organized by context.

    Shows all components grouped by parent context with types, descriptions,
    and dependency listings.
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
        components = Components.list_components_with_dependencies(scope)
        overview = Architecture.generate_overview(components)

        text_response(overview)

      {:error, reason} ->
        ArchitectureMapper.error(reason)
    end
  end

  defp text_response(content) do
    {:ok, content}
  end
end
