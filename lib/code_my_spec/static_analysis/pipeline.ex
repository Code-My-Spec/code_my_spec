defmodule CodeMySpec.StaticAnalysis.Pipeline do
  @moduledoc """
  Compilation and static analysis for the validation pipeline.

  Provides three public functions called by the StaticAnalysis context:

  - `compile/2` — run compiler, persist diagnostics as problems, block on errors
  - `resolve_analyzers/2` — merge role-derived + task-declared analyzers
  - `run_analyzers/3` — run resolved analyzers against changed files, persist problems

  ## Tuning

  The `@role_analyzers` map is the primary tuning surface. It maps file roles
  to the analyzers that should run when files of that role change. Task modules
  can augment this by implementing `analyzers/0`.
  """

  require Logger

  alias CodeMySpec.Compile
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Documents
  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemConverter
  alias CodeMySpec.StaticAnalysis.Runner
  alias CodeMySpec.Users.Scope

  # The tuning surface — file role → analyzers to run
  # Look here to understand "what runs when I change X?"
  @role_analyzers %{
    implementation: [:credo, :exunit_stale],
    test: [:credo, :exunit_stale],
    spec: [:validate_spec],
    bdd_spec: [:validate_bdd],
    qa_brief: [:validate_qa],
    qa_result: [:validate_qa],
    architecture: [],
    rule: [],
    config: [],
    review: [],
    integration: [],
    json: [],
    task_artifact: []
  }

  # -- Compilation --

  @doc """
  Compile the project and persist diagnostics as problems.

  Clears old compiler problems scoped to `changed_file_paths`, then persists
  new diagnostics. Returns `:ok` or `{:error, reason}` on compiler errors.
  """
  @spec compile(Scope.t(), [String.t()]) :: :ok | {:error, String.t()}
  def compile(%Scope{cwd: nil}, _changed_file_paths), do: :ok

  def compile(%Scope{cwd: cwd} = scope, _changed_file_paths) do
    start = System.monotonic_time(:millisecond)

    result = Compile.execute(cwd: cwd)
    diagnostics = result.data.compiler_results

    # Convert diagnostics to Problem structs
    problems =
      diagnostics
      |> Enum.map(&ProblemConverter.from_compiler/1)
      |> Enum.map(&%{&1 | project_id: scope.active_project_id})

    # Clear ALL compiler problems — mix compile gives us the complete picture,
    # so we replace everything rather than scoping to changed files
    Problems.clear_problems_for_source(scope, [source: "compiler"], :all)

    if problems != [] do
      Problems.create_problems(scope, problems)
    end

    ms = System.monotonic_time(:millisecond) - start
    errors = Enum.filter(problems, &(&1.severity == :error))
    warnings = Enum.filter(problems, &(&1.severity == :warning))

    Logger.info(
      "[Pipeline] Compile: #{length(errors)} error(s), #{length(warnings)} warning(s) (#{ms}ms)"
    )

    if errors != [] do
      {:error, format_compiler_errors(errors)}
    else
      :ok
    end
  end

  # -- Analyzer resolution --

  # Map analyzer atoms to the ProjectConfiguration field that gates them.
  # Analyzers not in this map are always eligible (validators etc.).
  @config_gated_analyzers %{
    credo: :credo,
    exunit_stale: :exunit,
    spex_stale: :spex
  }

  @doc """
  Resolve which analyzers to run by merging role-derived and task-declared,
  then filtering out analyzers that the project configuration has disabled.

  Sources:
  1. Role-derived from `@role_analyzers` based on changed file roles
  2. Task module `analyzers/0` callback (augments, not replaces)

  Config filter: analyzers whose corresponding `ProjectConfiguration` field
  is `:off` are removed. If `config` is `nil`, no filtering happens.
  """
  @spec resolve_analyzers(map() | nil, [map()], map() | nil) :: [atom()]
  def resolve_analyzers(task, changed_files, config \\ nil) do
    role_derived = analyzers_for_roles(changed_files)
    task_declared = task_analyzers(task)

    merged = (role_derived ++ task_declared) |> Enum.uniq()
    filtered = apply_config_filter(merged, config)

    module = task && task.session_type

    source =
      if task_declared != [] do
        type_name = module |> Atom.to_string() |> String.split(".") |> List.last()
        "role-derived #{inspect(role_derived)} + #{type_name}.analyzers/0 #{inspect(task_declared)}"
      else
        "role-derived"
      end

    dropped = merged -- filtered

    config_note =
      if dropped != [],
        do: " — dropped by config: #{inspect(dropped)}",
        else: ""

    Logger.info("[Pipeline] Analyzers: #{inspect(filtered)} (#{source}#{config_note})")
    filtered
  end

  defp apply_config_filter(analyzers, nil), do: analyzers

  defp apply_config_filter(analyzers, config) do
    Enum.reject(analyzers, fn analyzer ->
      case Map.get(@config_gated_analyzers, analyzer) do
        nil -> false
        field -> Map.get(config, field) == :off
      end
    end)
  end

  defp task_analyzers(nil), do: []

  defp task_analyzers(task) do
    module = task.session_type

    if module && function_exported?(module, :analyzers, 0) do
      module.analyzers()
    else
      []
    end
  end

  defp analyzers_for_roles(files) do
    files
    |> Enum.map(& &1.role)
    |> Enum.uniq()
    |> Enum.flat_map(fn role -> Map.get(@role_analyzers, role, []) end)
    |> Enum.uniq()
  end

  # -- Running analyzers --

  @doc """
  Run the resolved analyzers against changed files and persist problems.

  Expects only static analyzers and validators — runner analyzers like
  `:exunit_stale` / `:spex_stale` must be split out by the caller, since
  they execute as subprocesses rather than through `Runner`.
  """
  @spec run_analyzers(Scope.t(), [atom()], [map()]) :: :ok
  def run_analyzers(_scope, [], _changed_files), do: :ok

  def run_analyzers(scope, analyzers, changed_files) do
    run_analyzer_set(scope, analyzers, changed_files)
    :ok
  end

  # -- Internal analyzer execution --

  defp run_analyzer_set(_scope, [], _files), do: []

  defp run_analyzer_set(scope, analyzers, files) do
    component_map = build_component_map(files)
    file_paths = Enum.map(files, & &1.path)

    {static_analyzers, validators} = split_analyzers(analyzers)

    # Run static analyzers (credo, sobelow, etc.)
    static_problems = run_static_analyzers(scope, static_analyzers, file_paths)

    # Run validators (spec validation, qa validation, etc.)
    validation_problems = run_validators(scope, validators, files)

    all_problems = static_problems ++ validation_problems

    # Assign component_id from file records
    all_problems =
      Enum.map(all_problems, fn problem ->
        component_id = Map.get(component_map, problem.file_path)

        if component_id do
          %{problem | component_id: component_id}
        else
          problem
        end
      end)

    # Persist: clear old problems for sources that ran, insert new
    ran_sources = sources_for_analyzers(static_analyzers, validators)
    persist_problems(scope, all_problems, file_paths, ran_sources)

    if all_problems != [] do
      by_source =
        all_problems
        |> Enum.group_by(& &1.source)
        |> Enum.map_join(", ", fn {source, probs} -> "#{source}(#{length(probs)})" end)

      Logger.info("[Pipeline] Persisted #{length(all_problems)} problem(s) — #{by_source}")
    end

    all_problems
  end

  defp run_static_analyzers(_scope, [], _file_paths), do: []

  defp run_static_analyzers(scope, analyzer_atoms, file_paths) do
    Enum.flat_map(analyzer_atoms, fn atom ->
      start = System.monotonic_time(:millisecond)

      result = Runner.run(scope, atom, files: file_paths)
      ms = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, problems} ->
          Logger.info(
            "[Pipeline] #{atom}: #{length(problems)} problem(s) on #{length(file_paths)} file(s) (#{ms}ms)"
          )

          problems

        {:error, reason} ->
          Logger.warning("[Pipeline] #{atom}: failed (#{ms}ms) — #{reason}")
          []
      end
    end)
  end

  defp run_validators(_scope, [], _files), do: []

  defp run_validators(scope, validators, files) do
    Enum.flat_map(validators, fn validator ->
      start = System.monotonic_time(:millisecond)
      problems = run_validator(scope, validator, files)
      ms = System.monotonic_time(:millisecond) - start

      file_count =
        case validator do
          :validate_spec -> Enum.count(files, &(&1.role in [:spec, :review]))
          :validate_qa -> Enum.count(files, &(&1.role in [:qa_brief, :qa_result]))
          _ -> length(files)
        end

      Logger.info(
        "[Pipeline] #{validator}: #{length(problems)} problem(s) on #{file_count} file(s) (#{ms}ms)"
      )

      problems
    end)
  end

  defp run_validator(scope, :validate_spec, files) do
    files
    |> Enum.filter(&(&1.role in [:spec, :review]))
    |> Enum.flat_map(&validate_spec_file(scope, &1))
  end

  defp run_validator(scope, :validate_qa, files) do
    files
    |> Enum.filter(&(&1.role in [:qa_brief, :qa_result]))
    |> Enum.flat_map(&validate_qa_file(scope, &1))
  end

  defp run_validator(_scope, :validate_bdd, _files) do
    # BDD specs are .exs files — compiler step already catches syntax errors.
    # Runtime validation (spex passing) is handled by RequirementCalculator.
    []
  end

  defp run_validator(_scope, validator, _files) do
    Logger.warning("[Pipeline] Unknown validator: #{validator}")
    []
  end

  defp validate_spec_file(%Scope{cwd: cwd} = scope, file) do
    abs_path = Path.join(cwd, file.path)

    case File.read(abs_path) do
      {:ok, content} ->
        document_type =
          if file.role == :review do
            "design_review"
          else
            document_type_from_content(content)
          end

        case Documents.create_dynamic_document(content, document_type) do
          {:ok, _document} ->
            Files.mark_validated(file, true)
            []

          {:error, error} ->
            reason = to_string(error)
            Files.mark_validated(file, false, %{error: reason})

            [
              %Problem{
                severity: :error,
                source: "spec_validation",
                source_type: :static_analysis,
                file_path: file.path,
                message: reason,
                category: "validation",
                project_id: scope.active_project_id
              }
            ]
        end

      {:error, reason} ->
        Logger.warning("[Pipeline] Could not read #{abs_path}: #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.warning("[Pipeline] Spec validation error for #{file.path}: #{Exception.message(e)}")
      []
  end

  defp validate_qa_file(%Scope{cwd: cwd} = scope, file) do
    abs_path = Path.join(cwd, file.path)

    document_type =
      case file.role do
        :qa_brief -> "qa_story_brief"
        :qa_result -> "qa_result"
      end

    case File.read(abs_path) do
      {:ok, content} ->
        case Documents.create_dynamic_document(content, document_type) do
          {:ok, _document} ->
            Files.mark_validated(file, true)
            []

          {:error, error} ->
            reason = to_string(error)
            Files.mark_validated(file, false, %{error: reason})

            [
              %Problem{
                severity: :error,
                source: "qa_validation",
                source_type: :static_analysis,
                file_path: file.path,
                message: reason,
                category: "validation",
                project_id: scope.active_project_id
              }
            ]
        end

      {:error, reason} ->
        Logger.warning("[Pipeline] Could not read #{abs_path}: #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.warning("[Pipeline] QA validation error for #{file.path}: #{Exception.message(e)}")
      []
  end

  # Extract document type from spec content's ## Type section.
  # Mirrors the logic in FileSync.document_type_from_content/1.
  defp document_type_from_content(content) do
    type_section =
      content
      |> String.split("\n")
      |> Enum.drop_while(&(!String.match?(&1, ~r/^## Type$/)))
      |> Enum.drop(1)
      |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.first()

    case type_section do
      nil ->
        "spec"

      component_type ->
        type_def = ComponentRegistry.get_type(component_type)
        Map.get(type_def, :document_type, "spec")
    end
  end

  # Static analyzers go through Runner; validators are handled separately
  defp split_analyzers(analyzers) do
    Enum.split_with(analyzers, fn atom ->
      atom in [:credo, :sobelow, :spec_alignment]
    end)
  end

  # Map analyzer atoms to the source strings they produce in Problem records
  @analyzer_source_map %{
    credo: "credo",
    sobelow: "sobelow",
    spec_alignment: "spec_alignment",
    validate_spec: "spec_validation",
    validate_bdd: "spec_validation",
    validate_qa: "qa_validation"
  }

  defp sources_for_analyzers(static_analyzers, validators) do
    (static_analyzers ++ validators)
    |> Enum.map(&Map.get(@analyzer_source_map, &1, Atom.to_string(&1)))
    |> Enum.uniq()
  end

  # -- Problem persistence --

  defp persist_problems(scope, problems, file_paths, analyzer_sources) do
    # Always clear old problems for analyzers that ran, even if they found nothing
    Enum.each(analyzer_sources, fn source ->
      Problems.clear_problems_for_source(scope, [source: source], file_paths)
    end)

    if problems != [], do: Problems.create_problems(scope, problems)
  end

  # -- Formatting helpers --

  defp build_component_map(files) do
    files
    |> Enum.filter(& &1.component_id)
    |> Map.new(&{&1.path, &1.component_id})
  end

  defp format_compiler_errors(errors) do
    error_lines =
      Enum.map_join(errors, "\n", fn problem ->
        location =
          if problem.file_path do
            "#{problem.file_path}:#{problem.line || "?"}"
          else
            "unknown"
          end

        "  #{location} — #{problem.message}"
      end)

    """
    Compilation failed with #{length(errors)} error(s). Fix these before continuing:

    #{error_lines}
    """
  end
end
