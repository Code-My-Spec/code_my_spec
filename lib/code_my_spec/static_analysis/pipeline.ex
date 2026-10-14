defmodule CodeMySpec.StaticAnalysis.Pipeline do
  @moduledoc """
  Compilation and static analysis for the validation pipeline.

  Called through the StaticAnalysis context:

  - `compile/2` — run compiler, persist diagnostics, block on errors
  - `resolve_analyzers/3` — merge role-derived + task-declared, then filter by config
  - `run_analyzers/5` — run resolved in-process analyzers, persist problems
  - `task_analyzers/1`, `task_excluded_analyzers/1` — the active task's additions and opt-outs

  `@role_analyzers` is the tuning surface: file role → analyzers to run.
  Task modules can augment via an `analyzers/0` callback.
  """

  require Logger

  alias CodeMySpec.Compile
  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemConverter
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.StaticAnalysis.Runner
  alias CodeMySpec.Users.Scope

  @qa_journey_result_path CodeMySpec.Paths.qa_journey_result()

  # Which analyzers a changed role schedules. A role an analyzer reports
  # findings against has to schedule that analyzer, or editing the file can
  # never refresh the findings that block it: a `:test` edit schedules exunit,
  # because the suite is what the edit changed.
  @role_analyzers %{
    implementation: [:credo, :exunit_stale, :spex_stale],
    test: [:credo, :exunit_stale],
    test_support: [:credo, :exunit_stale],
    # Credo files findings against spex files, so editing one must schedule it.
    bdd_spec: [:credo, :spex_stale],
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

  Clears all compiler problems (mix compile produces the complete picture)
  and replaces with the new diagnostics. Returns `{:error, :no_environment}`
  without changing saved findings when there is no execution environment.
  """
  @spec compile(Scope.t(), keyword()) :: :ok | {:error, term()}
  def compile(scope, opts \\ [])

  def compile(%Scope{} = scope, opts) do
    cwd = opts[:cwd] || scope.cwd
    environment = StaticAnalysis.resolve_environment(opts, scope, cwd)

    if is_nil(environment) do
      {:error, :no_environment}
    else
      compile_in_environment(scope, opts, environment)
    end
  end

  defp compile_in_environment(scope, opts, environment) do
    start = System.monotonic_time(:millisecond)

    execute_opts = [environment: environment]

    execute_opts =
      case Keyword.get(opts, :compile_output_file) do
        nil -> execute_opts
        path -> Keyword.put(execute_opts, :output_file, path)
      end

    result = Compile.execute(execute_opts)

    problems =
      result.data.compiler_results
      |> Enum.map(&%{ProblemConverter.from_compiler(&1) | project_id: scope.active_project_id})

    Problems.clear_problems_for_source(scope, [source: "compiler"], :all)
    Problems.create_problems(scope, problems)

    {errors, warnings} = Enum.split_with(problems, &(&1.severity == :error))
    ms = System.monotonic_time(:millisecond) - start

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

  # Analyzer atom → ProjectConfiguration field that gates it.
  # Atoms not in this map are always eligible. Gating `spex_stale` is safe:
  # `start_analysis` and an agent's own `mix spex` still record spex runs.
  @config_gated_analyzers %{
    credo: :credo,
    exunit_stale: :exunit,
    spex_stale: :spex,
    validate_qa: :qa_validation
  }

  @doc """
  Resolve which analyzers to run.

  Three layers:
  - **Role-derived** — concerns that always apply to a file role (credo
    on code files, validators on spec files). Subject to the config
    filter: a project that turned a source off does not want it looked
    at just because a file of the matching role changed.
  - **Task-declared** — concerns the active task adds via `analyzers/0`.
    Never subject to the config filter (see below).
  - **Task-excluded** — concerns the active task removes via
    `excluded_analyzers/0`. ComponentTest uses this to opt out of
    `:exunit_stale` while the agent is writing tests, since exunit
    failures are expected until the implementation lands.

  Config gates role-derived inclusion only. A task-declared analyzer is
  the question the task's own gate depends on (`FixBddSpecs` names
  `spex_stale`); filtering it by config would make that gate unsatisfiable.
  """
  @spec resolve_analyzers(map() | nil, [map()], map()) :: [atom()]
  def resolve_analyzers(task, changed_files, config) do
    role_derived = analyzers_for_roles(changed_files)
    task_declared = task_analyzers(task)
    task_excluded = task_excluded_analyzers(task)

    role_kept =
      role_derived
      |> Enum.reject(&(&1 in task_excluded))
      |> apply_config_filter(config)

    task_kept = Enum.reject(task_declared, &(&1 in task_excluded))

    filtered = Enum.uniq(role_kept ++ task_kept)

    dropped_by_config = (role_derived -- task_excluded) -- role_kept

    Logger.info(
      "[Pipeline] Analyzers: #{inspect(filtered)} (#{resolve_source(role_derived, task_declared, task_excluded, task)}#{config_note(dropped_by_config)})"
    )

    filtered
  end

  defp resolve_source(_role_derived, [], [], _task), do: "role-derived"

  defp resolve_source(role_derived, task_declared, task_excluded, task) do
    type_name = task.session_type |> Atom.to_string() |> String.split(".") |> List.last()

    "role-derived #{inspect(role_derived)} + #{type_name}.analyzers/0 #{inspect(task_declared)}" <>
      excluded_note(type_name, task_excluded)
  end

  defp excluded_note(_type_name, []), do: ""

  defp excluded_note(type_name, excluded),
    do: " - #{type_name}.excluded_analyzers/0 #{inspect(excluded)}"

  defp config_note([]), do: ""
  defp config_note(dropped), do: " — dropped by config: #{inspect(dropped)}"

  defp apply_config_filter(analyzers, config) do
    Enum.reject(analyzers, fn analyzer ->
      case Map.get(@config_gated_analyzers, analyzer) do
        nil -> false
        field -> Map.get(config, field) == :off
      end
    end)
  end

  @doc """
  Analyzers the active task declares via `analyzers/0`. Not subject to the
  config filter (see `resolve_analyzers/3`).
  """
  @spec task_analyzers(map() | nil) :: [atom()]
  def task_analyzers(nil), do: []

  def task_analyzers(task) do
    module = task.session_type

    if module && Code.ensure_loaded?(module) && function_exported?(module, :analyzers, 0) do
      module.analyzers()
    else
      []
    end
  end

  @doc """
  Analyzers the task opts out of via `excluded_analyzers/0` (e.g.
  ComponentTest excluding `:exunit_stale` while tests are being written).
  """
  @spec task_excluded_analyzers(map() | nil) :: [atom()]
  def task_excluded_analyzers(nil), do: []

  def task_excluded_analyzers(task) do
    module = task.session_type

    if module && Code.ensure_loaded?(module) && function_exported?(module, :excluded_analyzers, 0) do
      module.excluded_analyzers()
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

  Returns `{:error, :no_environment}` without changing saved findings when
  there is no execution environment.

  Every analyzer scans the whole project and every source's problems are
  cleared project-wide before re-insert, whatever the config mode.
  """
  @spec run_analyzers(Scope.t(), [atom()], [map()], map(), keyword()) :: :ok | {:error, term()}
  def run_analyzers(scope, analyzers, changed_files, config \\ %{}, opts \\ [])
  def run_analyzers(_scope, [], _changed_files, _config, _opts), do: :ok

  def run_analyzers(scope, analyzers, changed_files, config, opts) do
    cwd = Keyword.get(opts, :cwd) || scope.cwd
    environment = StaticAnalysis.resolve_environment(opts, scope, cwd)

    if is_nil(environment) do
      {:error, :no_environment}
    else
      execution_opts =
        opts
        |> Keyword.put(:environment, environment)
        |> Keyword.put(:cwd, Keyword.get(opts, :cwd) || environment.cwd)

      run_analyzer_set(scope, analyzers, changed_files, config, execution_opts)
      :ok
    end
  end

  # -- Internal analyzer execution --

  defp run_analyzer_set(_scope, [], _files, _config, _opts), do: []

  defp run_analyzer_set(scope, analyzers, files, config, opts) do
    component_map = build_component_map(files)
    file_paths = Enum.map(files, & &1.path)

    {static_analyzers, validators} = split_analyzers(analyzers)

    all_problems =
      (run_static_analyzers(scope, static_analyzers, file_paths, config, opts) ++
         run_validators(scope, validators, files, opts[:environment]))
      |> Enum.map(&stamp_component_id(&1, component_map))

    source_scopes = source_scopes_for(static_analyzers, validators, file_paths, config)
    persist_problems(scope, all_problems, source_scopes)

    log_persisted(all_problems)
    all_problems
  end

  defp stamp_component_id(problem, component_map) do
    case Map.get(component_map, problem.file_path) do
      nil -> problem
      component_id -> %{problem | component_id: component_id}
    end
  end

  defp log_persisted([]), do: :ok

  defp log_persisted(problems) do
    by_source =
      problems
      |> Enum.group_by(& &1.source)
      |> Enum.map_join(", ", fn {source, probs} -> "#{source}(#{length(probs)})" end)

    Logger.info("[Pipeline] Persisted #{length(problems)} problem(s) — #{by_source}")
  end

  defp run_static_analyzers(_scope, [], _file_paths, _config, _opts), do: []

  defp run_static_analyzers(scope, analyzer_atoms, file_paths, config, opts) do
    Enum.flat_map(analyzer_atoms, fn atom ->
      analyzer_files = files_for_analyzer(atom, file_paths, config)

      runner_opts =
        [files: analyzer_files, environment: opts[:environment], cwd: opts[:cwd]]
        |> with_test_output(atom, opts)

      start = System.monotonic_time(:millisecond)

      result = Runner.run(scope, atom, runner_opts)
      ms = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, problems} ->
          log_analyzer_success(atom, problems, analyzer_files, ms)
          problems

        {:error, reason} ->
          Logger.warning("[Pipeline] #{atom}: failed (#{ms}ms) — #{reason}")
          []
      end
    end)
  end

  # Cassette escape hatch: `:credo_output_file` is read instead of spawning
  # `mix credo`, like the runner analyzers' `*_output_file` options.
  defp with_test_output(runner_opts, :credo, validation_opts) do
    case Keyword.get(validation_opts, :credo_output_file) do
      nil -> runner_opts
      path -> Keyword.put(runner_opts, :output_file, path)
    end
  end

  defp with_test_output(runner_opts, _atom, _opts), do: runner_opts

  defp log_analyzer_success(atom, problems, analyzer_files, ms) do
    file_count =
      if is_nil(analyzer_files), do: "all", else: Integer.to_string(length(analyzer_files))

    Logger.info(
      "[Pipeline] #{atom}: #{length(problems)} problem(s) on #{file_count} file(s) (#{ms}ms)"
    )
  end

  # `nil` means every file, for every analyzer. Mode decides what blocks
  # (`Validation`'s `apply_mode/4`), not what is scanned; scanning all is what
  # makes `source_scopes_for/4`'s clear-all correct.
  # See knowledge/analysis, "Scan all, clear all".
  defp files_for_analyzer(_atom, _file_paths, _config), do: nil

  defp run_validators(_scope, [], _files, _environment), do: []

  defp run_validators(scope, validators, files, environment) do
    Enum.flat_map(validators, fn validator ->
      start = System.monotonic_time(:millisecond)
      problems = run_validator(scope, validator, files, environment)
      ms = System.monotonic_time(:millisecond) - start

      file_count =
        case validator do
          :validate_qa -> Enum.count(files, &(&1.role in [:qa_brief, :qa_result]))
          _ -> length(files)
        end

      Logger.info(
        "[Pipeline] #{validator}: #{length(problems)} problem(s) on #{file_count} file(s) (#{ms}ms)"
      )

      problems
    end)
  end

  defp run_validator(scope, :validate_qa, files, environment) do
    fun = &qa_document_type/2

    files
    |> Enum.filter(&(&1.role in [:qa_brief, :qa_result]))
    |> Enum.flat_map(&validate_document(scope, environment, &1, "qa_validation", fun))
  end

  defp run_validator(_scope, validator, _files, _environment) do
    Logger.warning("[Pipeline] Unknown validator: #{validator}")
    []
  end

  defp validate_document(scope, environment, file, source, document_type_fn) do
    case Environments.read_file(environment, file.path) do
      {:ok, content} ->
        run_document_validation(scope, file, source, document_type_fn.(file, content), content)

      {:error, reason} ->
        Logger.warning("[Pipeline] Could not read #{file.path}: #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.warning("[Pipeline] #{source} error for #{file.path}: #{Exception.message(e)}")
      []
  end

  defp run_document_validation(scope, file, source, document_type, content) do
    case Documents.create_dynamic_document(content, document_type, strict: true) do
      {:ok, _document} ->
        Files.mark_validated(file, true)
        []

      {:error, error} ->
        reason = to_string(error)
        Files.mark_validated(file, false, %{error: reason})

        [
          %Problem{
            severity: :error,
            source: source,
            source_type: :static_analysis,
            file_path: file.path,
            message: reason,
            category: "validation",
            project_id: scope.active_project_id
          }
        ]
    end
  end

  defp qa_document_type(%{role: :qa_brief}, _content), do: "qa_story_brief"

  # A story result and the journey result share the `:qa_result` role; only
  # the path tells which schema applies (same as `qa_plan` / `qa_journey_plan`).
  defp qa_document_type(%{role: :qa_result} = file, _content) do
    case Map.get(file, :path) do
      path when path == @qa_journey_result_path -> "qa_journey_result"
      _ -> "qa_result"
    end
  end

  defp split_analyzers(analyzers) do
    Enum.split_with(analyzers, fn atom ->
      atom in [:credo, :sobelow]
    end)
  end

  @analyzer_source_map %{
    credo: "credo",
    sobelow: "sobelow",
    validate_qa: "qa_validation"
  }

  # Each entry pairs a problem `source` (the DB string) with the scope to clear
  # before re-inserting: always `:all`, because every analyzer scans everything.
  # See knowledge/analysis, "Scan all, clear all".
  defp source_scopes_for(static_analyzers, validators, _file_paths, _config) do
    (static_analyzers ++ validators)
    |> Enum.map(fn atom ->
      {Map.get(@analyzer_source_map, atom, Atom.to_string(atom)), :all}
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  # -- Problem persistence --

  # Clear per-source even when an analyzer ran clean — otherwise stale
  # problems from the previous turn linger.
  defp persist_problems(scope, problems, source_scopes) do
    Enum.each(source_scopes, fn {source, file_scope} ->
      Problems.clear_problems_for_source(scope, [source: source], file_scope)
    end)

    Problems.create_problems(scope, problems)
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
