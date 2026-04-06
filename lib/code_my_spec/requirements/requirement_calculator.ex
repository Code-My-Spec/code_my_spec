defmodule CodeMySpec.Requirements.RequirementCalculator do
  @moduledoc """
  Computes requirement satisfaction from File records, Problems, and entity fields.

  Dispatches on `definition.check_type` instead of pattern-matching on requirement
  names. Handles component, story, and project requirements with a unified set of
  check types:

  - `:file_exists`   — File record with configured role exists
  - `:file_valid`    — File record with configured role has valid: true
  - `:path_exists`   — File at configured path exists in project file list
  - `:field_present` — Field on entity struct is not nil
  - `:no_problems`   — Zero Problem records from configured source
  - `:tests_passing` — Zero exunit Problems
  - `:spex_passing`  — Zero spex Problems
  """

  import Ecto.Query

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Files.File
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type computed_requirement :: %{
          name: String.t(),
          satisfied: boolean(),
          details: map()
        }

  # -- Public API --

  @doc """
  Compute satisfaction for all requirements of a component.
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
  Compute satisfaction for a single requirement definition against an entity.
  """
  def compute_one(scope, entity, definition, files, ctx \\ nil) do
    {satisfied, details} = check(definition, scope, entity, files, ctx)
    %{name: definition.name, satisfied: satisfied, details: details}
  end

  # -- Check dispatch by check_type --

  defp check(%{check_type: :file_exists, config: config}, scope, entity, files, _ctx) do
    role = config_role(config)
    has_role?(files, role, expected_path(scope, entity, role))
  end

  defp check(%{check_type: :file_valid, config: config}, _scope, _entity, files, _ctx) do
    role = config_role(config)
    has_valid_role?(files, role)
  end

  defp check(%{check_type: :path_exists, config: config}, _scope, _entity, _files, ctx) do
    cond do
      path = config["path"] || config[:path] ->
        check_path_exists(ctx, path)

      prefix = config["path_prefix"] || config[:path_prefix] ->
        check_path_prefix(ctx, prefix)

      true ->
        {false, %{reason: "path_exists check missing path or path_prefix config"}}
    end
  end

  defp check(%{check_type: :field_present, config: config}, _scope, entity, _files, _ctx) do
    field = config_field(config)
    value = Map.get(entity, field)

    if not is_nil(value) do
      {true, %{status: "#{field} is set"} |> Map.put(field, value)}
    else
      {false, %{reason: "#{field} is not set"}}
    end
  end

  defp check(%{check_type: :no_problems, config: config}, scope, entity, _files, ctx) do
    source = config_source(config)
    count = get_problem_count(scope, entity_id(entity), source, ctx)

    if count == 0 do
      {true, %{status: "No #{source} problems"}}
    else
      {false, %{reason: "#{count} #{source} problem(s)", count: count}}
    end
  end

  defp check(%{check_type: :tests_passing}, scope, entity, files, ctx) do
    # Must have a test file before declaring tests passing
    has_test_file = Enum.any?(files, &(&1.role == :test))

    if not has_test_file do
      {false, %{reason: "No test file exists yet"}}
    else
      count = get_problem_count(scope, entity_id(entity), "exunit", ctx)

      if count == 0 do
        {true, %{status: "No test failures"}}
      else
        {false, %{reason: "#{count} test failure(s)", count: count}}
      end
    end
  end

  defp check(%{check_type: :spex_passing}, _scope, entity, files, ctx) do
    # For stories, check that BDD spec files exist before declaring passing
    bdd_files = Enum.filter(files, &(&1.role == :bdd_spec))

    if bdd_files == [] do
      {false, %{reason: "No BDD spec files exist yet"}}
    else
      spex_problems = get_global_problem_count(ctx, "spex")

      if spex_problems == 0 do
        {true, %{status: "All BDD specs passing"}}
      else
        {false, %{reason: "#{spex_problems} failing BDD spec(s)"}}
      end
    end
  end

  # Special case: project_setup delegates to its evaluate function
  defp check(%{name: "project_setup"}, scope, _entity, _files, _ctx) do
    case CodeMySpec.AgentTasks.ProjectSetup.evaluate(scope, %{}) do
      {:ok, :valid} -> {true, %{status: "All setup steps complete"}}
      {:ok, :invalid, _} -> {false, %{reason: "Setup steps incomplete"}}
      _ -> {false, %{reason: "Setup evaluation failed"}}
    end
  end

  # Issues checks — special cases until we model issues as problems
  defp check(%{name: "issues_triaged"}, scope, _entity, _files, _ctx) do
    triageable =
      Issues.list_by_status(scope, :incoming)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    if triageable == [],
      do: {true, %{status: "No untriaged issues at medium+ severity"}},
      else: {false, %{reason: "#{length(triageable)} untriaged medium+ issues"}}
  end

  defp check(%{name: "issues_resolved"}, scope, _entity, _files, _ctx) do
    unresolved =
      Issues.list_by_status(scope, :accepted)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    if unresolved == [],
      do: {true, %{status: "No unresolved medium+ issues"}},
      else: {false, %{reason: "#{length(unresolved)} unresolved medium+ issues"}}
  end

  # Fallback for definitions without check_type (legacy or unknown)
  defp check(%{check_type: nil, name: name}, _scope, _entity, _files, _ctx) do
    {false, %{reason: "No check_type defined for requirement: #{name}"}}
  end

  defp check(%{check_type: check_type}, _scope, _entity, _files, _ctx) do
    {false, %{reason: "Unknown check_type: #{check_type}"}}
  end

  # -- Config helpers --

  defp config_role(config) do
    config[:role] || config["role"] || raise "file check missing :role in config"
  end

  defp config_source(config) do
    config[:source] || config["source"] || raise "no_problems check missing :source in config"
  end

  defp config_field(config) do
    config[:field] || config["field"] || raise "field_present check missing :field in config"
  end

  # -- Entity helpers --

  defp entity_id(%Component{id: id}), do: id
  defp entity_id(%{id: id}), do: id

  defp expected_path(%Scope{active_project: project}, %Component{} = component, role) do
    file_key = role_to_file_key(role)

    CodeMySpec.Utils.component_files(component, project)
    |> Map.get(file_key)
  end

  defp expected_path(_scope, _entity, _role), do: nil

  defp role_to_file_key(:spec), do: :spec_file
  defp role_to_file_key(:implementation), do: :code_file
  defp role_to_file_key(:test), do: :test_file
  defp role_to_file_key(:review), do: :review_file
  defp role_to_file_key(:json), do: :json_file
  defp role_to_file_key(_), do: nil

  # -- Path checks (project-level) --

  defp check_path_exists(%{files_by_path: fbp}, path) when is_map(fbp) do
    if Map.has_key?(fbp, path) do
      {true, %{path: path}}
    else
      {false, %{reason: "File missing: #{path}"}}
    end
  end

  defp check_path_exists(_, path), do: {false, %{reason: "File missing: #{path}"}}

  defp check_path_prefix(%{files_by_project: files}, prefix) when is_list(files) do
    count = Enum.count(files, &String.starts_with?(&1.path, prefix))

    if count > 0 do
      {true, %{status: "#{count} file(s) at #{prefix}"}}
    else
      {false, %{reason: "No files at #{prefix}"}}
    end
  end

  defp check_path_prefix(_, prefix), do: {false, %{reason: "No files at #{prefix}"}}

  # -- File checks --

  defp has_role?(files, role, expected_path \\ nil) do
    if Enum.any?(files, &(&1.role == role)) do
      {true, %{status: "#{role} file exists"}}
    else
      details = %{reason: "#{role} file missing"}
      details = if expected_path, do: Map.put(details, :expected_path, expected_path), else: details
      {false, details}
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

  defp get_global_problem_count(%{problems_by_source: pbs}, source) when is_map(pbs) do
    Map.get(pbs, source, 0)
  end

  defp get_global_problem_count(_, _source), do: 0
end
