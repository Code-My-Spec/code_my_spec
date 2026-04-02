defmodule CodeMySpec.Requirements.RequirementCalculator do
  @moduledoc """
  Computes requirement satisfaction from File records and Problems.

  Accepts an optional preloaded context (from `Preloader.load/1`) to avoid
  N+1 queries. Falls back to per-component queries when no context is provided.
  """

  import Ecto.Query

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Files.File
  alias CodeMySpec.Requirements.Preloader
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

  Accepts an optional `ctx` (preloaded context from Preloader) to avoid queries.
  """
  @spec compute_component(Scope.t(), Component.t(), Preloader.context() | nil) :: [computed_requirement()]
  def compute_component(%Scope{} = scope, %Component{} = component, ctx \\ nil) do
    definitions = ComponentRegistry.get_requirements_for_type(component.type)
    files = get_files(scope, component.id, ctx)

    Enum.map(definitions, fn definition ->
      compute_one(scope, component, definition, files, ctx)
    end)
  end

  @doc """
  Compute satisfaction for a single named requirement.
  """
  def compute_one(scope, component, definition, files, ctx \\ nil) do
    {satisfied, details} = check(definition.name, scope, component, files, ctx)
    %{name: definition.name, satisfied: satisfied, details: details}
  end

  # -- File existence checks --

  defp check("spec_file", _scope, _component, files, _ctx), do: has_role?(files, :spec)
  defp check("implementation_file", _scope, _component, files, _ctx), do: has_role?(files, :implementation)
  defp check("test_file", _scope, _component, files, _ctx), do: has_role?(files, :test)
  defp check("review_file", _scope, _component, files, _ctx), do: has_role?(files, :review)
  defp check("json_file", _scope, _component, files, _ctx), do: has_role?(files, :json)

  # -- File validity checks --

  defp check("spec_valid", _scope, _component, files, _ctx), do: has_valid_role?(files, :spec)
  defp check("review_valid", _scope, _component, files, _ctx), do: has_valid_role?(files, :review)
  defp check("test_spec_alignment", _scope, _component, files, _ctx), do: has_valid_role?(files, :test)

  # -- Problem-based checks --

  defp check("tests_passing", scope, component, _files, ctx) do
    count = get_problem_count(scope, component.id, "exunit", ctx)

    if count == 0 do
      {true, %{status: "No test failures"}}
    else
      {false, %{reason: "#{count} test failure(s)", count: count}}
    end
  end

  # Container requirements — check children's file state directly.
  defp check("context_specs", scope, component, _files, ctx) do
    children = get_children(component, ctx)

    if children == [] do
      {true, %{status: "No children"}}
    else
      incomplete =
        Enum.reject(children, fn child ->
          child_files = get_files(scope, child.id, ctx)
          {spec_ok, _} = has_role?(child_files, :spec)
          {valid_ok, _} = has_valid_role?(child_files, :spec)
          spec_ok and valid_ok
        end)

      if incomplete == [] do
        {true, %{status: "All #{length(children)} child specs complete"}}
      else
        {false, %{reason: "#{length(incomplete)} children need specs",
                  unsatisfied: Enum.map(incomplete, & &1.module_name)}}
      end
    end
  end

  defp check("context_implementation", scope, component, _files, ctx) do
    children = get_children(component, ctx)

    if children == [] do
      {true, %{status: "No children"}}
    else
      incomplete =
        Enum.reject(children, fn child ->
          child_files = get_files(scope, child.id, ctx)
          {impl_ok, _} = has_role?(child_files, :implementation)
          {test_ok, _} = has_role?(child_files, :test)
          test_problems = get_problem_count(scope, child.id, "exunit", ctx)
          impl_ok and test_ok and test_problems == 0
        end)

      if incomplete == [] do
        {true, %{status: "All #{length(children)} child implementations complete"}}
      else
        {false, %{reason: "#{length(incomplete)} children need implementation",
                  unsatisfied: Enum.map(incomplete, & &1.module_name)}}
      end
    end
  end

  defp check(name, _scope, _component, _files, _ctx) do
    {false, %{reason: "Unknown requirement: #{name}"}}
  end

  # -- Data access (preloaded or query) --

  defp get_files(_scope, component_id, %{files_by_component: fbc}) do
    Map.get(fbc, component_id, [])
  end

  defp get_files(%Scope{active_project_id: project_id}, component_id, nil) do
    File
    |> where([f], f.project_id == ^project_id and f.component_id == ^component_id)
    |> Repo.all()
  end

  defp get_problem_count(_scope, component_id, source, %{problems_by_component: pbc}) do
    pbc
    |> Map.get(component_id, %{})
    |> Map.get(source, 0)
  end

  defp get_problem_count(%Scope{active_project_id: project_id}, component_id, source, nil) do
    Problem
    |> where([p], p.project_id == ^project_id and p.component_id == ^component_id and p.source == ^source)
    |> Repo.aggregate(:count)
  end

  # -- Data access: children --

  defp get_children(component, %{components: components}) do
    Enum.filter(components, &(&1.parent_component_id == component.id))
  end

  defp get_children(component, nil) do
    component = Repo.preload(component, :child_components, force: true)
    case component.child_components do
      %Ecto.Association.NotLoaded{} -> []
      children when is_list(children) -> children
    end
  end

  # -- Pure helpers --

  defp has_role?(files, role) do
    if Enum.any?(files, &(&1.role == role)) do
      {true, %{status: "#{role} file exists"}}
    else
      {false, %{reason: "#{role} file missing"}}
    end
  end

  defp has_valid_role?(files, role) do
    case Enum.find(files, &(&1.role == role)) do
      nil -> {false, %{reason: "#{role} file missing"}}
      %{valid: true} -> {true, %{status: "#{role} file valid"}}
      %{valid: false, validation_errors: errors} -> {false, %{reason: "#{role} file invalid", errors: errors}}
      %{valid: nil} -> {false, %{reason: "#{role} file not yet validated"}}
    end
  end
end
