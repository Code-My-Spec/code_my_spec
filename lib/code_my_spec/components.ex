defmodule CodeMySpec.Components do
  @moduledoc """
  Manages component definitions, metadata, type classification, and inter-component dependencies for architectural design.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Repo,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  alias CodeMySpec.Components.{
    Component,
    ComponentRepository,
    DependencyRepository
  }

  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

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

  # The PubSub message always — the UI wants every change — and the graph
  # event only when `graph:` says the graph has something to read.
  defp broadcast(%Scope{} = scope, message, opts \\ []) do
    key = scope.user.id

    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:components", message)

    if Keyword.get(opts, :graph, true) do
      kind = component_event_kind(message)
      GraphInputs.event(scope, "Components", kind, %{}, graph_entities(message), vantage_of(kind))
    end

    :ok
  end

  # Every checkout, whatever the kind: the `components` table has no
  # `working_copy_id`, and a retype or new dependency moves the template and
  # edges at every vantage. Per-checkout effects arrive as `files_synced`.
  defp vantage_of(_kind), do: :project_wide

  # Handlers settle `architecture_designed` from these kinds and keep their
  # marks (`@partial`), so the component still goes through
  # `compute_entity/4`, the only path that creates or reaps rows.
  # See knowledge/requirements_graph/checkers, "Announcing writes".
  defp component_event_kind({:created, _}), do: "component_created"
  defp component_event_kind({:deleted, _}), do: "component_deleted"
  defp component_event_kind(_message), do: "component_changed"

  # The component and nothing else. Not its parent: a component's unit of
  # computation is already its family (`Preloader.load_component_family/2`),
  # and naming the parent recomputes the grandparent's whole family. Not
  # `:project`: `architecture_designed` is settled from these kinds by a
  # handler, far cheaper than recomputing project nodes at every vantage.
  # See knowledge/requirements_graph/checkers, "Announcing writes".
  defp graph_entities({_verb, %{id: id}}), do: [{"component", id}]

  defp graph_entities(_message), do: []

  defdelegate list_components(scope), to: ComponentRepository
  defdelegate count_components(scope), to: ComponentRepository
  defdelegate list_child_components(scope, parent_component_id), to: ComponentRepository
  defdelegate list_components_with_dependencies(scope), to: ComponentRepository
  defdelegate any_authored?(scope), to: ComponentRepository
  defdelegate list_contexts(scope), to: ComponentRepository
  defdelegate list_contexts_with_dependencies(scope), to: ComponentRepository
  defdelegate list_orphaned_contexts(scope), to: ComponentRepository
  defdelegate get_component!(scope, id), to: ComponentRepository
  defdelegate get_component_by_module_name(scope, id), to: ComponentRepository
  defdelegate get_component(scope, id), to: ComponentRepository
  defdelegate list_all_descendants(scope, parent_component_id), to: ComponentRepository
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

    with {:ok, updated = %Component{}} <-
           ComponentRepository.update_component(scope, component, attrs, opts) do
      if Keyword.get(opts, :broadcast, true),
        do: broadcast(scope, {:updated, updated}, graph: structural_change?(component, updated))

      {:ok, updated}
    end
  end

  # What the graph reads off a component row: its type (the template), its
  # parent (the family and the tree edges) and its name (identity). A change to
  # anything else, such as `description`, announces nothing to the graph.
  @structural [:type, :parent_component_id, :module_name]

  defp structural_change?(%Component{} = before, %Component{} = after_) do
    Enum.any?(@structural, &(Map.get(before, &1) != Map.get(after_, &1)))
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

  defdelegate list_dependencies(scope), to: DependencyRepository
  defdelegate list_component_dependencies(scope, component_id), to: DependencyRepository
  defdelegate get_dependency!(scope, id), to: DependencyRepository
  defdelegate get_dependency_between(scope, source_id, target_id), to: DependencyRepository
  defdelegate create_dependency(scope, attrs), to: DependencyRepository
  defdelegate update_dependency(scope, dependency, attrs), to: DependencyRepository
  defdelegate delete_dependency(scope, dependency), to: DependencyRepository
  defdelegate validate_dependency_graph(scope), to: DependencyRepository

  @spec resolve_dependency_order(CodeMySpec.Users.Scope.t()) ::
          {:ok, [CodeMySpec.Components.Component.t()]}
  defdelegate resolve_dependency_order(scope), to: DependencyRepository

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
