defmodule CodeMySpec.Components.Tools.UpdateComponent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "update_component"

  @impl true
  def description do
    """
    Updates a component.
    Include all fields in the input that you want to update.
    They will be persisted exactly as you send them.
    """
  end

  @impl true
  def params do
    %{
      name: :string,
      type:
        {:meta,
         {:enum,
          [
            "context",
            "coordination_context",
            "live_context",
            "schema",
            "behaviour",
            "json",
            "liveview",
            "liveview_component",
            "controller",
            "module",
            "infrastructure"
          ]},
         [
           description:
             "Component type: context, coordination_context, live_context, schema, behaviour, json, liveview, liveview_component, controller, module, infrastructure."
         ]},
      description: :string,
      module_name: :string,
      component_id: {:required, :string},
      parent_component_id:
        {:meta, :string, [description: "The component this one belongs under, e.g. its context"]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, component} <- find_component(scope, params.component_id),
         {:ok, component} <-
           Components.update_component(scope, component, Map.drop(params, [:component_id])) do
      ComponentsMapper.component_response(component)
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        ComponentsMapper.validation_error(changeset)

      {:error, :not_found} ->
        ComponentsMapper.not_found_error()

      {:error, atom} ->
        ComponentsMapper.error(atom)
    end
  end

  defp find_component(scope, id) do
    case Components.get_component(scope, id) do
      nil -> {:error, :not_found}
      component -> {:ok, component}
    end
  end
end
