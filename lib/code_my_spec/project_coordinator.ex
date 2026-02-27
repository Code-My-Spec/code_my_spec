defmodule CodeMySpec.ProjectCoordinator do
  @moduledoc """
  Synchronizes project component requirements with file system reality.

  Takes components, file list, and test results, analyzes everything, and returns
  the full nested component tree with statuses and requirements. Can filter to
  get the next actionable components.

  Also provides dependency-chain traversal for orchestrators: given a target
  component, `build_dependency_chain/2` collects its transitive dependencies and
  `find_next_in_chain/2` walks bottom-up to find the first component ready for work.
  """

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.DependencyTree
  alias CodeMySpec.ProjectCoordinator.ComponentAnalyzer
  alias CodeMySpec.ProjectCoordinator.NextActionable
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Tests.TestRun
  alias CodeMySpec.Users.Scope

  @type component_list :: [Component.t()]
  @type file_list :: [String.t()]

  @spec sync_project_requirements(Scope.t(), file_list(), TestRun.t(), keyword()) ::
          component_list()
  def sync_project_requirements(
        %Scope{} = scope,
        file_list,
        %TestRun{failures: failures},
        opts \\ []
      )
      when is_list(file_list) and is_list(failures) and is_list(opts) do
    scope
    |> Components.list_components_with_dependencies()
    |> ComponentAnalyzer.analyze_components(
      file_list,
      failures,
      Keyword.put(opts, :scope, scope)
    )
  end

  @doc """
  Find the next actionable requirement for the project.

  Recursively descends: project → stories → components → dependencies.
  Returns `{:ok, %Requirement{}}` with a `satisfied_by` task module, or `:complete`.
  """
  @spec get_next_actions(Scope.t()) :: {:ok, Requirement.t()} | :complete
  def get_next_actions(%Scope{} = scope) do
    project = scope.active_project |> Repo.preload(:requirements)
    NextActionable.call(scope, project)
  end

  # ============================================================================
  # Dependency Chain Traversal
  # ============================================================================

  @doc """
  Build the dependency chain for a component, ordered bottom-up (leaves first).

  Collects transitive dependencies, filters to chain members, topologically sorts
  via `DependencyTree.build/1`.
  """
  @spec build_dependency_chain(Component.t(), [Component.t()]) :: [Component.t()]
  def build_dependency_chain(target, all_components) do
    component_map = Map.new(all_components, &{&1.id, &1})

    chain_ids =
      target
      |> collect_transitive_deps(component_map, MapSet.new())
      |> MapSet.put(target.id)

    all_components
    |> Enum.filter(&MapSet.member?(chain_ids, &1.id))
    |> DependencyTree.build()
  end

  @doc """
  Find the next component ready for work in the dependency chain.

  Walks bottom-up: returns the first component that has unsatisfied requirements
  AND whose own dependencies are satisfied.
  """
  @spec find_next_in_chain(Component.t(), [Component.t()]) ::
          {:ready, Component.t()} | {:blocked, [Component.t()]} | :complete
  def find_next_in_chain(target, all_components) do
    chain = build_dependency_chain(target, all_components)

    ready =
      Enum.find(chain, fn c ->
        has_unsatisfied_requirements?(c) and dependencies_satisfied?(c)
      end)

    cond do
      ready != nil -> {:ready, ready}
      Enum.any?(chain, &has_unsatisfied_requirements?/1) -> {:blocked, chain}
      true -> :complete
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp has_unsatisfied_requirements?(%Component{requirements: requirements})
       when is_list(requirements) do
    Enum.any?(requirements, fn req -> not req.satisfied end)
  end

  defp has_unsatisfied_requirements?(_), do: false

  defp dependencies_satisfied?(component) do
    dep_req =
      (component.requirements || [])
      |> Enum.find(fn r -> r.name == "dependencies_satisfied" end)

    is_nil(dep_req) or dep_req.satisfied
  end

  defp collect_transitive_deps(component, component_map, visited) do
    deps =
      case component.dependencies do
        %Ecto.Association.NotLoaded{} -> []
        deps -> deps
      end

    Enum.reduce(deps, visited, fn dep, acc ->
      collect_dep(dep, component_map, acc)
    end)
  end

  defp collect_dep(dep, component_map, visited) do
    if MapSet.member?(visited, dep.id) do
      visited
    else
      visited = MapSet.put(visited, dep.id)

      case Map.get(component_map, dep.id) do
        nil -> visited
        dep_component -> collect_transitive_deps(dep_component, component_map, visited)
      end
    end
  end
end
