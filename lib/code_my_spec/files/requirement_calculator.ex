defmodule CodeMySpec.Files.RequirementCalculator do
  @moduledoc """
  Computes requirement satisfaction from File records and Problems.

  No persisted requirements needed. Given a component and its requirement
  definitions (from the registry), returns computed satisfaction status
  by querying Files and Problems.

  This replaces the checker → persist → query cycle with direct computation.
  """

  import Ecto.Query

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Files.File
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type computed_requirement :: %{
          name: String.t(),
          satisfied: boolean(),
          details: map()
        }

  @doc """
  Compute satisfaction for all requirements of a component.

  Returns a list of `%{name, satisfied, details}` maps — one per requirement
  definition in the registry for this component's type.
  """
  @spec compute_component(Scope.t(), Component.t()) :: [computed_requirement()]
  def compute_component(%Scope{} = scope, %Component{} = component) do
    definitions = ComponentRegistry.get_requirements_for_type(component.type)
    files = load_component_files(scope, component.id)

    Enum.map(definitions, fn definition ->
      compute_one(scope, component, definition, files)
    end)
  end

  @doc """
  Check if all requirements for a component are satisfied.
  """
  @spec component_satisfied?(Scope.t(), Component.t()) :: boolean()
  def component_satisfied?(%Scope{} = scope, %Component{} = component) do
    scope
    |> compute_component(component)
    |> Enum.all?(& &1.satisfied)
  end

  @doc """
  Compute satisfaction for a single named requirement.
  """
  @spec compute_one(Scope.t(), Component.t(), map(), [File.t()]) :: computed_requirement()
  def compute_one(scope, component, definition, files) do
    {satisfied, details} = check(definition.name, scope, component, files)
    %{name: definition.name, satisfied: satisfied, details: details}
  end

  # -- File existence checks --

  defp check("spec_file", _scope, _component, files) do
    has_role?(files, :spec)
  end

  defp check("implementation_file", _scope, _component, files) do
    has_role?(files, :implementation)
  end

  defp check("test_file", _scope, _component, files) do
    has_role?(files, :test)
  end

  defp check("review_file", _scope, _component, files) do
    has_role?(files, :review)
  end

  defp check("json_file", _scope, _component, files) do
    has_role?(files, :json)
  end

  # -- File validity checks --

  defp check("spec_valid", _scope, _component, files) do
    has_valid_role?(files, :spec)
  end

  defp check("review_valid", _scope, _component, files) do
    has_valid_role?(files, :review)
  end

  defp check("test_spec_alignment", _scope, _component, files) do
    has_valid_role?(files, :test)
  end

  # -- Problem-based checks --

  defp check("tests_passing", scope, component, _files) do
    count = count_problems(scope, component.id, "exunit")

    if count == 0 do
      {true, %{status: "No test failures"}}
    else
      {false, %{reason: "#{count} test failure(s)", count: count}}
    end
  end

  # -- Dependency checks --

  defp check("dependencies_satisfied", scope, component, _files) do
    deps = load_dependencies(scope, component)

    case deps do
      [] ->
        {true, %{status: "No dependencies"}}

      deps ->
        unsatisfied =
          Enum.reject(deps, &component_satisfied?(scope, &1))

        if unsatisfied == [] do
          {true, %{status: "All #{length(deps)} dependencies satisfied"}}
        else
          {false,
           %{
             reason: "#{length(unsatisfied)} unsatisfied dependencies",
             unsatisfied: Enum.map(unsatisfied, & &1.module_name)
           }}
        end
    end
  end

  # -- Hierarchical checks --

  defp check("children_designs", scope, component, _files) do
    children = load_children(scope, component)

    case children do
      [] ->
        {true, %{status: "No children"}}

      children ->
        unsatisfied =
          Enum.reject(children, fn child ->
            child_files = load_component_files(scope, child.id)
            {spec_ok, _} = has_role?(child_files, :spec)
            {valid_ok, _} = has_valid_role?(child_files, :spec)
            spec_ok and valid_ok
          end)

        if unsatisfied == [] do
          {true, %{status: "All #{length(children)} children designed"}}
        else
          {false,
           %{
             reason: "#{length(unsatisfied)} children missing specs",
             unsatisfied: Enum.map(unsatisfied, & &1.module_name)
           }}
        end
    end
  end

  defp check("children_implementations", scope, component, _files) do
    children = load_children(scope, component)

    case children do
      [] ->
        {true, %{status: "No children"}}

      children ->
        unsatisfied =
          Enum.reject(children, fn child ->
            child_files = load_component_files(scope, child.id)
            {impl_ok, _} = has_role?(child_files, :implementation)
            {test_ok, _} = has_role?(child_files, :test)
            test_problems = count_problems(scope, child.id, "exunit")
            impl_ok and test_ok and test_problems == 0
          end)

        if unsatisfied == [] do
          {true, %{status: "All #{length(children)} children implemented"}}
        else
          {false,
           %{
             reason: "#{length(unsatisfied)} children incomplete",
             unsatisfied: Enum.map(unsatisfied, & &1.module_name)
           }}
        end
    end
  end

  # Catch-all for unknown requirement names
  defp check(name, _scope, _component, _files) do
    {false, %{reason: "Unknown requirement: #{name}"}}
  end

  # -- Private helpers --

  defp has_role?(files, role) do
    if Enum.any?(files, &(&1.role == role)) do
      {true, %{status: "#{role} file exists"}}
    else
      {false, %{reason: "#{role} file missing"}}
    end
  end

  defp has_valid_role?(files, role) do
    case Enum.find(files, &(&1.role == role)) do
      nil ->
        {false, %{reason: "#{role} file missing"}}

      %{valid: true} ->
        {true, %{status: "#{role} file valid"}}

      %{valid: false, validation_errors: errors} ->
        {false, %{reason: "#{role} file invalid", errors: errors}}

      %{valid: nil} ->
        {false, %{reason: "#{role} file not yet validated"}}
    end
  end

  defp load_component_files(%Scope{active_project_id: project_id}, component_id) do
    File
    |> where([f], f.project_id == ^project_id and f.component_id == ^component_id)
    |> Repo.all()
  end

  defp count_problems(%Scope{active_project_id: project_id}, component_id, source) do
    Problem
    |> where([p], p.project_id == ^project_id and p.component_id == ^component_id and p.source == ^source)
    |> Repo.aggregate(:count)
  end

  defp load_dependencies(%Scope{} = _scope, %Component{} = component) do
    component = Repo.preload(component, :dependencies)

    case component.dependencies do
      %Ecto.Association.NotLoaded{} -> []
      deps when is_list(deps) -> deps
    end
  end

  defp load_children(%Scope{} = _scope, %Component{} = component) do
    component = Repo.preload(component, :child_components, force: true)

    case component.child_components do
      %Ecto.Association.NotLoaded{} -> []
      children when is_list(children) -> children
    end
  end
end
