defmodule CodeMySpec.Components.Tools.OrphanedContexts do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "orphaned_contexts"

  @impl true
  def description do
    "Lists all contexts with no user story and no dependencies"
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        orphaned_contexts = Components.list_orphaned_contexts(scope)
        ComponentsMapper.components_list_response(orphaned_contexts)

      {:error, atom} ->
        ComponentsMapper.error(atom)
    end
  end
end
