defmodule CodeMySpec.Components.Tools.AddDependency do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "add_dependency"

  @impl true
  def description do
    """
    Records that one component depends on another.

    Components are authored as records (3aeb66cf), and their dependencies with
    them. Until this tool an edge could only arrive by a spec file's
    `## Dependencies` being synced, so an architecture designed through the tools
    had no way to say what depended on what.
    """
  end

  @impl true
  def params do
    %{
      source_component_id:
        {:required, {:meta, :string, [description: "The component that depends on the other"]}},
      target_component_id:
        {:required, {:meta, :string, [description: "The component it depends on"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, source} <- fetch(scope, params.source_component_id),
         {:ok, target} <- fetch(scope, params.target_component_id),
         {:ok, _dependency} <-
           Components.create_dependency(scope, %{
             source_component_id: source.id,
             target_component_id: target.id,
             provenance: :authored
           }) do
      {:ok, "`#{source.module_name}` now depends on `#{target.module_name}`."}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        ComponentsMapper.validation_error(changeset)

      {:error, {:not_found, id}} ->
        ComponentsMapper.error("No component #{id} in this project.")
    end
  end

  # Scoped, because `create_dependency` is not: it would link two components in
  # any project.
  defp fetch(scope, id) do
    case Components.get_component(scope, id) do
      nil -> {:error, {:not_found, id}}
      component -> {:ok, component}
    end
  end
end
