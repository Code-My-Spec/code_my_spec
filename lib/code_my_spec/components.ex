defmodule CodeMySpec.Components do
  @moduledoc """
  Manages component definitions, metadata, type classification, and inter-component dependencies for architectural design.
  """

  alias CodeMySpec.Components.{
    Component,
    ComponentRepository,
    DependencyRepository,
    SimilarComponentRepository,
    Registry
  }

  alias CodeMySpec.Users.Scope
  require Logger

  @doc """
  Subscribes to scoped notifications about any component changes.

  The broadcasted messages match the pattern:

    * {:created, %Component{}}
    * {:updated, %Component{}}
    * {:deleted, %Component{}}

  """
  def subscribe_components(%Scope{} = scope) do
    key = scope.user.id

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:components")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.user.id

    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:components", message)
  end

  defdelegate list_components(scope), to: ComponentRepository
  defdelegate count_components(scope), to: ComponentRepository
  defdelegate list_child_components(scope, parent_component_id), to: ComponentRepository
  defdelegate list_components_with_dependencies(scope), to: ComponentRepository
  defdelegate list_contexts(scope), to: ComponentRepository
  defdelegate list_contexts_with_dependencies(scope), to: ComponentRepository
  defdelegate list_orphaned_contexts(scope), to: ComponentRepository
  defdelegate get_component!(scope, id), to: ComponentRepository
  defdelegate get_component_by_module_name(scope, id), to: ComponentRepository
  defdelegate get_component(scope, id), to: ComponentRepository
  defdelegate show_architecture(scope), to: ComponentRepository
  defdelegate upsert_component(scope, attrs), to: ComponentRepository

  defdelegate search_components_by_module_name(scope, module_name_pattern),
    to: ComponentRepository

  defdelegate create_components_with_dependencies(scope, component_attrs_list, dependencies),
    to: ComponentRepository

  @doc """
  Creates a component.

  ## Examples

      iex> create_component(scope, %{field: value})
      {:ok, %Component{}}

      iex> create_component(scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_component(%Scope{} = scope, attrs) do
    with {:ok, component = %Component{}} <- ComponentRepository.create_component(scope, attrs) do
      broadcast(scope, {:created, component})
      {:ok, component}
    end
  end

  @doc """
  Updates a component.

  ## Examples

      iex> update_component(scope, component, %{field: new_value})
      {:ok, %Component{}}

      iex> update_component(scope, component, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_component(%Scope{} = scope, %Component{} = component, attrs, opts \\ []) do
    true = component.project_id == scope.active_project.id

    with {:ok, component = %Component{}} <-
           ComponentRepository.update_component(scope, component, attrs, opts) do
      if Keyword.get(opts, :broadcast, true), do: broadcast(scope, {:updated, component})
      {:ok, component}
    end
  end

  @doc """
  Deletes a component.

  ## Examples

      iex> delete_component(scope, component)
      {:ok, %Component{}}

      iex> delete_component(scope, component)
      {:error, %Ecto.Changeset{}}

  """
  def delete_component(%Scope{} = scope, %Component{} = component) do
    true = component.project_id == scope.active_project.id

    with {:ok, component = %Component{}} <- ComponentRepository.delete_component(scope, component) do
      broadcast(scope, {:deleted, component})
      {:ok, component}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking component changes.

  ## Examples

      iex> change_component(scope, component)
      %Ecto.Changeset{data: %Component{}}

  """
  def change_component(%Scope{} = scope, %Component{} = component, attrs \\ %{}) do
    true = component.project_id == scope.active_project.id

    Component.changeset(component, attrs, scope)
  end

  defdelegate components_with_unsatisfied_requirements(scope), to: ComponentRepository
  defdelegate list_dependencies(scope), to: DependencyRepository
  defdelegate list_component_dependencies(scope, component_id), to: DependencyRepository
  defdelegate get_dependency!(scope, id), to: DependencyRepository
  defdelegate create_dependency(scope, attrs), to: DependencyRepository
  defdelegate delete_dependency(scope, dependency), to: DependencyRepository
  defdelegate validate_dependency_graph(scope), to: DependencyRepository

  @spec resolve_dependency_order(CodeMySpec.Users.Scope.t()) ::
          {:ok, [CodeMySpec.Components.Component.t()]}
  defdelegate resolve_dependency_order(scope), to: DependencyRepository

  # Similar Components
  defdelegate list_similar_components(scope, component), to: SimilarComponentRepository

  defdelegate add_similar_component(scope, component, similar_component),
    to: SimilarComponentRepository

  defdelegate remove_similar_component(scope, component, similar_component),
    to: SimilarComponentRepository

  defdelegate sync_similar_components(scope, component, similar_ids),
    to: SimilarComponentRepository

  defdelegate preload_similar_components(scope, components), to: SimilarComponentRepository
  defdelegate list_referenced_by(scope, component), to: SimilarComponentRepository
  defdelegate get_requirements_for_type(component_type), to: Registry

  @doc """
  Returns requirement definitions for a component based on its type, with optional filtering.

  Retrieves static requirement definitions from the Registry and applies
  filtering based on options.

  ## Options

    * `:include` - list of requirement names to include (if empty, includes all)
    * `:exclude` - list of requirement names to exclude
    * `:artifact_types` - list of artifact types to filter by (if empty, includes all)

  ## Examples

      iex> get_requirement_definitions(scope, %Component{type: "schema"}, [])
      [%RequirementDefinition{name: "spec_file", ...}, ...]

      iex> get_requirement_definitions(scope, component, include: ["spec_file", "spec_valid"])
      [%RequirementDefinition{name: "spec_file", ...}, %RequirementDefinition{name: "spec_valid", ...}]

      iex> get_requirement_definitions(scope, component, artifact_types: [:tests])
      [%RequirementDefinition{artifact_type: :tests, ...}, ...]

  """
  @spec get_requirement_definitions(Scope.t(), Component.t(), keyword()) :: [
          CodeMySpec.Requirements.RequirementDefinition.t()
        ]
  def get_requirement_definitions(_scope, %Component{type: type}, opts \\ []) do
    include_types = Keyword.get(opts, :include, [])
    exclude_types = Keyword.get(opts, :exclude, [])
    artifact_types = Keyword.get(opts, :artifact_types, [])

    Registry.get_requirements_for_type(type)
    |> Enum.filter(fn %{name: name, artifact_type: artifact_type} ->
      exclude = exclude_types != [] and name in exclude_types

      include =
        (include_types != [] and name in include_types) or include_types == []

      artifact_match =
        artifact_types == [] or artifact_type in artifact_types

      include && !exclude && artifact_match
    end)
  end

  @doc """
  Determines if a component is a bounded context.

  Detection logic:
  1. Primary: explicit type == "context"
  2. Fallback: module naming convention - contexts have exactly 2 parts (MyApp.ContextName)

  ## Examples

      iex> context?(%Component{type: "context"})
      true

      iex> context?(%Component{type: "repository", module_name: "MyApp.Accounts.AccountRepository"})
      false

      iex> context?(%Component{type: nil, module_name: "MyApp.Accounts"})
      true

      iex> context?(%Component{type: nil, module_name: "MyApp.Accounts.User"})
      false

  """
  @spec context?(Component.t()) :: boolean()
  def context?(%{type: "context"}), do: true
  def context?(%{type: type}) when not is_nil(type), do: false

  def context?(%{module_name: module_name}) when is_binary(module_name) do
    length(String.split(module_name, ".")) == 2
  end

  def context?(_), do: false
end
