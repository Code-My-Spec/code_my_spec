defmodule CodeMySpec.McpServers.Components.Tools.UpdateComponent do
  @moduledoc """
  Updates a component.
  Include all fields in the input that you want to update.
  They will be persisted exactly as you send them.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Types
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :component_id, :string, required: true
    field :name, :string

    # Every authorable type (3aeb66cf): this offered context and
    # coordination_context only, so a component authored as anything else
    # could never be corrected to its real type.
    field :type, {:enum, Types.all()},
      description: "Component type: #{Enum.join(Types.all(), ", ")}."

    field :module_name, :string
    field :description, :string

    field :parent_component_id, :string,
      description: "The component this one belongs under, e.g. its context"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, component} <- find_component(scope, params.component_id),
         {:ok, component} <-
           Components.update_component(scope, component, Map.drop(params, [:component_id])) do
      {:reply, ComponentsMapper.component_response(component), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, ComponentsMapper.validation_error(changeset), frame}

      {:error, :not_found} ->
        {:reply, ComponentsMapper.not_found_error(), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  defp find_component(scope, id) do
    case Components.get_component(scope, id) do
      nil -> {:error, :not_found}
      component -> {:ok, component}
    end
  end
end
