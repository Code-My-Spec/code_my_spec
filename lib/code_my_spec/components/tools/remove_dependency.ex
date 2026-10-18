defmodule CodeMySpec.Components.Tools.RemoveDependency do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "remove_dependency"

  @impl true
  def description do
    """
    Removes one component's dependency on another. The other half of
    `AddDependency`.
    """
  end

  @impl true
  def params do
    %{
      source_component_id:
        {:required, {:meta, :string, [description: "The component that depends on the other"]}},
      target_component_id:
        {:required,
         {:meta, :string, [description: "The component it should no longer depend on"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         %{} = dependency <-
           Components.get_dependency_between(
             scope,
             params.source_component_id,
             params.target_component_id
           ),
         {:ok, _removed} <- Components.delete_dependency(scope, dependency) do
      {:ok,
       "`#{dependency.source_component.module_name}` no longer depends on " <>
         "`#{dependency.target_component.module_name}`."}
    else
      nil ->
        ComponentsMapper.error("No such dependency in this project.")

      {:error, %Ecto.Changeset{} = changeset} ->
        ComponentsMapper.validation_error(changeset)
    end
  end
end
