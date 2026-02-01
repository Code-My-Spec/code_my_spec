defmodule CodeMySpec.Components.ComponentRepository do
  import Ecto.Query, warn: false

  require Logger

  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Components.Component

  @spec list_components(Scope.t()) :: [Component.t()]
  def list_components(%Scope{active_project_id: project_id}) do
    Component
    |> where([c], c.project_id == ^project_id)
    |> preload([:project, :child_components])
    |> Repo.all()
  end

  @spec count_components(Scope.t()) :: non_neg_integer()
  def count_components(%Scope{active_project_id: project_id}) do
    Component
    |> where([c], c.project_id == ^project_id)
    |> Repo.aggregate(:count, :id)
  end

  @spec list_child_components(Scope.t(), integer()) :: [Component.t()]
  def list_child_components(%Scope{active_project_id: project_id}, parent_component_id) do
    Component
    |> where([c], c.parent_component_id == ^parent_component_id and c.project_id == ^project_id)
    |> order_by([c], asc: c.name)
    |> preload([:requirements])
    |> Repo.all()
  end

  @doc """
  Lists all descendants of a component recursively.

  Returns all components that are children, grandchildren, etc. of the given
  parent component, traversing the entire subtree depth-first.

  Uses a single query to fetch all project components, then builds the
  descendant list in memory to avoid N+1 query problems.
  """
  @spec list_all_descendants(Scope.t(), Ecto.UUID.t()) :: [Component.t()]
  def list_all_descendants(%Scope{active_project_id: project_id} = _scope, parent_component_id) do
    # Single query to get all components with requirements preloaded
    all_components =
      Component
      |> where([c], c.project_id == ^project_id)
      |> preload([:requirements])
      |> Repo.all()

    # Build parent->children lookup map in memory
    children_map =
      all_components
      |> Enum.group_by(& &1.parent_component_id)

    # Recursively collect descendants using the in-memory map
    collect_descendants_from_map(children_map, parent_component_id, [])
  end

  defp collect_descendants_from_map(children_map, parent_id, acc) do
    children = Map.get(children_map, parent_id, [])

    Enum.reduce(children, acc ++ children, fn child, inner_acc ->
      collect_descendants_from_map(children_map, child.id, inner_acc)
    end)
  end

  @spec get_component!(Scope.t(), integer()) :: Component.t()
  def get_component!(%Scope{active_project_id: project_id}, id) do
    Component
    |> where([c], c.id == ^id and c.project_id == ^project_id)
    |> preload([:project, :requirements])
    |> Repo.one!()
  end

  @spec get_component(Scope.t(), integer()) :: Component.t() | nil
  def get_component(%Scope{active_project_id: project_id}, id) do
    Component
    |> where([c], c.id == ^id and c.project_id == ^project_id)
    |> preload([:project, :requirements])
    |> Repo.one()
  end

  @spec create_component(Scope.t(), map()) :: {:ok, Component.t()} | {:error, Ecto.Changeset.t()}
  def create_component(%Scope{} = scope, attrs) do
    %Component{}
    |> Component.changeset(attrs, scope)
    |> Repo.insert()
  end

  @spec upsert_component(Scope.t(), map()) :: Component.t() | {:error, Ecto.Changeset.t()}
  def upsert_component(%Scope{} = scope, attrs) do
    %Component{}
    |> Component.changeset(attrs, scope)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:module_name, :project_id],
      returning: true
    )
    |> case do
      {:ok, component} -> Repo.preload(component, [:project, :child_components])
      {:error, _changeset} = error -> error
    end
  end

  @spec update_component(Scope.t(), Component.t(), map(), list()) ::
          {:ok, Component.t()} | {:error, Ecto.Changeset.t()}
  def update_component(%Scope{} = scope, %Component{} = component, attrs, opts \\ []) do
    if Keyword.get(opts, :persist, true) do
      component
      |> Component.changeset(attrs, scope)
      |> Repo.update()
    else
      component
      |> Component.changeset(attrs, scope)
      |> Ecto.Changeset.apply_action(:update)
    end
  end

  @spec delete_component(Scope.t(), Component.t()) ::
          {:ok, Component.t()} | {:error, Ecto.Changeset.t()}
  def delete_component(%Scope{}, %Component{} = component) do
    Repo.delete(component)
  end

  @spec list_contexts(Scope.t()) :: [Component.t()]
  def list_contexts(%Scope{active_project_id: project_id}) do
    Component
    |> where([c], c.project_id == ^project_id)
    |> where([c], c.type == "context" or c.type == "coordination_context")
    |> Repo.all()
  end

  @spec list_contexts_with_dependencies(Scope.t()) :: [Component.t()]
  def list_contexts_with_dependencies(%Scope{active_project_id: project_id}) do
    Component
    |> where([c], c.project_id == ^project_id)
    |> where([c], c.type == "context" or c.type == "coordination_context")
    |> preload([
      :project,
      :dependencies,
      :dependents,
      :stories,
      outgoing_dependencies: :target_component,
      incoming_dependencies: :source_component
    ])
    |> Repo.all()
  end

  @spec list_components_with_dependencies(Scope.t()) :: [Component.t()]
  def list_components_with_dependencies(%Scope{active_project_id: project_id}) do
    Component
    |> where([c], c.project_id == ^project_id)
    |> preload([
      :project,
      :dependencies,
      :dependents,
      :stories,
      outgoing_dependencies: :target_component,
      incoming_dependencies: :source_component
    ])
    |> Repo.all()
  end

  @spec get_component_with_dependencies(Scope.t(), integer()) :: Component.t() | nil
  def get_component_with_dependencies(%Scope{active_project_id: project_id}, id) do
    Component
    |> where([c], c.id == ^id and c.project_id == ^project_id)
    |> preload([
      :dependencies,
      :dependents,
      outgoing_dependencies: :target_component,
      incoming_dependencies: :source_component
    ])
    |> Repo.one()
  end

  @spec get_component_by_module_name(Scope.t(), String.t()) :: Component.t() | nil
  def get_component_by_module_name(%Scope{active_project_id: project_id}, module_name) do
    Component
    |> where([c], c.module_name == ^module_name and c.project_id == ^project_id)
    |> preload([:requirements])
    |> Repo.one()
  end

  @spec list_components_by_type(Scope.t(), atom()) :: [Component.t()]
  def list_components_by_type(%Scope{active_project_id: project_id}, type) do
    Component
    |> where([c], c.type == ^type and c.project_id == ^project_id)
    |> Repo.all()
  end

  @spec search_components_by_name(Scope.t(), String.t()) :: [Component.t()]
  def search_components_by_name(%Scope{active_project_id: project_id}, name_pattern) do
    search_term = "%#{name_pattern}%"

    Component
    |> where([c], c.project_id == ^project_id)
    |> where([c], ilike(c.name, ^search_term))
    |> Repo.all()
  end

  @spec search_components_by_module_name(Scope.t(), String.t()) :: [Component.t()]
  def search_components_by_module_name(%Scope{active_project_id: project_id}, module_name_pattern) do
    search_term = "%#{module_name_pattern}%"

    Component
    |> where([c], c.project_id == ^project_id)
    |> where([c], ilike(c.module_name, ^search_term))
    |> Repo.all()
  end

  @spec show_architecture(Scope.t()) :: [%{component: Component.t(), depth: integer()}]
  def show_architecture(%Scope{active_project_id: project_id}) do
    root_components =
      Component
      |> where([c], c.project_id == ^project_id)
      |> join(:inner, [c], s in assoc(c, :stories))
      |> distinct([c], c.id)
      |> preload([
        :stories,
        outgoing_dependencies: [
          target_component: [
            outgoing_dependencies: [
              target_component: [
                outgoing_dependencies: [
                  target_component: [
                    outgoing_dependencies: [
                      target_component: [
                        outgoing_dependencies: [
                          target_component: [
                            outgoing_dependencies: [
                              target_component: [
                                outgoing_dependencies: :target_component
                              ]
                            ]
                          ]
                        ]
                      ]
                    ]
                  ]
                ]
              ]
            ]
          ]
        ]
      ])
      |> Repo.all()

    Enum.map(root_components, &%{component: &1, depth: 0})
  end

  @spec list_orphaned_contexts(Scope.t()) :: [Component.t()]
  def list_orphaned_contexts(%Scope{} = scope) do
    all_components = list_components_with_dependencies(scope)

    # Get all component IDs that are reachable from entry points (components with stories)
    entry_components =
      Enum.filter(all_components, fn c ->
        length(c.stories || []) > 0
      end)

    dependency_ids =
      entry_components
      |> Enum.flat_map(fn c -> get_all_dependency_ids(c, all_components) end)
      |> MapSet.new()

    # Filter for contexts that have no stories and are not dependencies of entry points
    all_components
    |> Enum.filter(fn c ->
      c.type == "context" and
        length(c.stories || []) == 0 and
        not MapSet.member?(dependency_ids, c.id)
    end)
  end

  defp get_all_dependency_ids(component, all_components, visited \\ MapSet.new()) do
    if MapSet.member?(visited, component.id) do
      []
    else
      visited = MapSet.put(visited, component.id)

      direct_deps =
        Enum.map(component.outgoing_dependencies || [], fn dep ->
          dep.target_component.id
        end)

      # Recursively get dependencies of dependencies
      indirect_deps =
        (component.outgoing_dependencies || [])
        |> Enum.flat_map(fn dep ->
          case Enum.find(all_components, &(&1.id == dep.target_component.id)) do
            nil -> []
            dep_component -> get_all_dependency_ids(dep_component, all_components, visited)
          end
        end)

      direct_deps ++ indirect_deps
    end
  end

  @doc """
  Creates multiple components with their dependencies in a transaction.

  Returns `{:ok, components}` if all operations succeed, or `{:error, reason}` if any fail.

  ## Parameters
    * `scope` - The user scope
    * `component_attrs_list` - List of component attribute maps
    * `dependencies` - List of dependency module name strings

  ## Examples

      iex> create_components_with_dependencies(scope, [%{name: "Foo", ...}], ["MyApp.Bar"])
      {:ok, [%Component{}]}

      iex> create_components_with_dependencies(scope, [%{name: ""}], [])
      {:error, %Ecto.Changeset{}}

  """
  @spec create_components_with_dependencies(Scope.t(), [map()], [String.t()]) ::
          {:ok, [Component.t()]} | {:error, term()}
  def create_components_with_dependencies(%Scope{} = scope, component_attrs_list, dependencies) do
    Repo.transaction(fn ->
      # Create all components
      created_components =
        Enum.reduce_while(component_attrs_list, [], fn attrs, acc ->
          case create_component(scope, attrs) do
            {:ok, component} -> {:cont, [component | acc]}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
        end)

      case created_components do
        {:error, changeset} ->
          Repo.rollback(changeset)

        components ->
          components = Enum.reverse(components)

          # Create dependencies
          case create_dependencies_for_components(scope, components, dependencies) do
            :ok -> components
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp create_dependencies_for_components(_scope, _components, []), do: :ok

  defp create_dependencies_for_components(scope, components, dependencies) do
    alias CodeMySpec.Components.DependencyRepository

    dependencies
    |> Enum.reduce_while(:ok, fn dep_module_name, _acc ->
      case get_component_by_module_name(scope, dep_module_name) do
        nil ->
          {:cont, :ok}

        target_component ->
          dependency_attrs = %{
            source_component_id: List.first(components).id,
            target_component_id: target_component.id
          }

          case DependencyRepository.create_dependency(scope, dependency_attrs) do
            {:ok, _} -> {:cont, :ok}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
      end
    end)
  end

  @spec components_with_unsatisfied_requirements(Scope.t()) :: [Component.t()]
  def components_with_unsatisfied_requirements(%Scope{active_project_id: project_id}) do
    Component
    |> where([c], c.project_id == ^project_id)
    |> join(:inner, [c], r in assoc(c, :requirements))
    |> where([c, r], r.satisfied == false)
    |> distinct([c], c.id)
    |> preload(:requirements)
    |> Repo.all()
  end

  @spec components_ready_for_work(Scope.t()) :: [Component.t()]
  def components_ready_for_work(%Scope{active_project_id: project_id}) do
    # Get components that either have no requirements or all requirements are satisfied
    components_with_requirements =
      Component
      |> where([c], c.project_id == ^project_id)
      |> join(:inner, [c], r in assoc(c, :requirements))
      |> where([c, r], r.satisfied == false)
      |> select([c], c.id)
      |> Repo.all()

    Component
    |> where([c], c.project_id == ^project_id)
    |> where([c], c.id not in ^components_with_requirements)
    |> preload(:requirements)
    |> Repo.all()
  end
end
