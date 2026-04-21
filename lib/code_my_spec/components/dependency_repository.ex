defmodule CodeMySpec.Components.DependencyRepository do
  @moduledoc """
  Repository for Dependency data access.
  """

  import Ecto.Query, warn: false
  alias CodeMySpec.Repo
  alias CodeMySpec.Components.{Dependency, Component}
  alias CodeMySpec.Users.Scope

  @doc """
  Returns the list of dependencies for components in the given scope.
  """
  @spec list_dependencies(Scope.t()) :: [Dependency.t()]
  def list_dependencies(%Scope{active_project_id: project_id}) do
    from(d in Dependency,
      join: sc in Component,
      on: d.source_component_id == sc.id,
      where: sc.project_id == ^project_id,
      preload: [:source_component, :target_component]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of dependencies for a specific component (outgoing dependencies).
  """
  @spec list_component_dependencies(Scope.t(), binary()) :: [Dependency.t()]
  def list_component_dependencies(%Scope{active_project_id: project_id}, component_id) do
    from(d in Dependency,
      join: sc in Component,
      on: d.source_component_id == sc.id,
      where: sc.project_id == ^project_id and d.source_component_id == ^component_id,
      preload: [:target_component]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single dependency by ID within scope.
  """
  @spec get_dependency!(Scope.t(), non_neg_integer()) :: Dependency.t()
  def get_dependency!(%Scope{active_project_id: project_id}, id) do
    from(d in Dependency,
      join: sc in Component,
      on: d.source_component_id == sc.id,
      where: d.id == ^id and sc.project_id == ^project_id,
      preload: [:source_component, :target_component]
    )
    |> Repo.one!()
  end

  @doc """
  Creates a dependency.
  """
  @spec create_dependency(Scope.t(), map()) ::
          {:ok, Dependency.t()} | {:error, Ecto.Changeset.t()}
  def create_dependency(%Scope{} = _scope, attrs) do
    %Dependency{}
    |> Dependency.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a dependency.
  """
  @spec delete_dependency(Scope.t(), Dependency.t()) ::
          {:ok, Dependency.t()} | {:error, Ecto.Changeset.t()}
  def delete_dependency(%Scope{}, %Dependency{} = dependency) do
    Repo.delete(dependency)
  end

  @doc """
  Deletes a dependency.
  """
  @spec delete_dependency(Dependency.t()) ::
          {:ok, Dependency.t()} | {:error, Ecto.Changeset.t()}
  def delete_dependency(%Dependency{} = dependency) do
    Repo.delete(dependency)
  end

  @doc """
  Simple circular dependency check - looks for direct cycles.
  """
  @spec validate_dependency_graph(Scope.t()) :: :ok | {:error, list()}
  def validate_dependency_graph(%Scope{active_project_id: project_id}) do
    circular_deps =
      from(d1 in Dependency,
        join: d2 in Dependency,
        on:
          d1.source_component_id == d2.target_component_id and
            d1.target_component_id == d2.source_component_id,
        join: sc in Component,
        on: d1.source_component_id == sc.id,
        where: sc.project_id == ^project_id,
        preload: [:source_component, :target_component]
      )
      |> Repo.all()

    case circular_deps do
      [] -> :ok
      cycles -> {:error, format_cycles(cycles)}
    end
  end

  @doc """
  Basic topological sort - components with no dependencies first.
  """
  @spec resolve_dependency_order(Scope.t()) :: {:ok, [Component.t()]}
  def resolve_dependency_order(%Scope{active_project_id: project_id}) do
    components_with_deps =
      from(c in Component,
        left_join: d in Dependency,
        on: d.source_component_id == c.id,
        where: c.project_id == ^project_id,
        group_by: c.id,
        select: {c, count(d.id)}
      )
      |> Repo.all()

    sorted =
      components_with_deps
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    {:ok, sorted}
  end

  defp format_cycles(cycles) do
    Enum.map(cycles, fn dep ->
      %{
        components: [
          component_summary(dep.source_component),
          component_summary(dep.target_component)
        ],
        path: [dep.source_component.name, dep.target_component.name]
      }
    end)
  end

  defp component_summary(component) do
    %{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name
    }
  end
end
