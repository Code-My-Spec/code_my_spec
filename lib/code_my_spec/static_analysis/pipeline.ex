defmodule CodeMySpec.StaticAnalysis.Pipeline do
  @moduledoc """
  Compilation and static analysis for the validation pipeline.

  Three public functions called by the StaticAnalysis context:

  - `compile/1` — run compiler, persist diagnostics, block on errors
  - `resolve_analyzers/3` — merge role-derived + task-declared, then filter by config
  - `run_analyzers/3` — run resolved analyzers against changed files, persist problems

  `@role_analyzers` is the tuning surface: file role → analyzers to run.
  Task modules can augment via an `analyzers/0` callback.
  """

  require Logger

  alias CodeMySpec.Compile
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemConverter
  alias CodeMySpec.StaticAnalysis.Runner
  alias CodeMySpec.Users.Scope

  @role_analyzers %{
    implementation: [:credo, :exunit_stale, :spex_stale],
    test: [:credo],
    spec: [:validate_spec],
    bdd_spec: [:validate_bdd, :spex_stale],
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
  and replaces with the new diagnostics. Returns `:ok` or `{:error, reason}`
  when compilation has errors.
  """
  @spec compile(Scope.t(), keyword()) :: :ok | {:error, String.t()}
  def compile(scope, opts \\ [])
  def compile(%Scope{cwd: nil}, _opts), do: :ok

  def compile(%Scope{} = scope, opts) do
    start = System.monotonic_time(:millisecond)

    execute_opts = [environment: scope.environment]

    execute_opts =
      case Keyword.get(opts, :compile_output_file) do
        nil -> execute_opts
        path -> Keyword.put(execute_opts, :output_file, path)
      end

    result = Compile.execute(execute_opts)

    problems =
      result.data.compiler_results
      |> Enum.map(&ProblemConverter.from_compiler/1)
      |> Enum.map(&%{&1 | project_id: scope.active_project_id})

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
  # Atoms not in this map are always eligible.
  # `spex_stale` is deliberately absent: the `spex` config decides whether
  # a spex failure BLOCKS the stop, not whether the suite runs. The
  # specs-passing gate needs a fresh run to flip a story to specs-ready,
  # so letting `spex: :off` suppress the analyzer would make
  # `bdd_specs_passing` permanently unsatisfiable and clamp every story
  # behind it — the failure mode that got the node deleted in bab2f792.
  #
  # Same split credo already has: the mode decides blocking, not looking.
  @config_gated_analyzers %{
    credo: :credo,
    exunit_stale: :exunit,
    validate_spec: :spec_validation,
    validate_bdd: :spec_validation,
    validate_qa: :qa_validation
  }

  @doc """
  Resolve which analyzers to run.

  Three layers:
  - **Role-derived** — concerns that always apply to a file role (credo
    on code files, validators on spec files).
  - **Task-declared** — concerns the active task adds via `analyzers/0`.
  - **Task-excluded** — concerns the active task removes via
    `excluded_analyzers/0`. ComponentTest uses this to opt out of
    `:exunit_stale` while the agent is writing tests, since exunit
    failures are expected until the implementation lands.

  After merging the first two and subtracting the third, any analyzer
  whose `ProjectConfiguration` field is `:off` gets dropped.
  """
  @spec resolve_analyzers(map() | nil, [map()], map()) :: [atom()]
  def resolve_analyzers(task, changed_files, config) do
    role_derived = analyzers_for_roles(changed_files)
    task_declared = task_analyzers(task)
    task_excluded = task_excluded_analyzers(task)

    merged =
      (role_derived ++ task_declared)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in task_excluded))

    filtered = apply_config_filter(merged, config)

    Logger.info(
      "[Pipeline] Analyzers: #{inspect(filtered)} (#{resolve_source(role_derived, task_declared, task_excluded, task)}#{config_note(merged -- filtered)})"
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

  defp task_analyzers(nil), do: []

  defp task_analyzers(task) do
    module = task.session_type

    if module && function_exported?(module, :analyzers, 0) do
      module.analyzers()
    else
      []
    end
  end

  @doc """
  Analyzers the task opts out of via `excluded_analyzers/0`.

  Public because `Validation`'s no-changed-files self-heal path checks every
  config-enabled source against the run ledger and must still respect task
  exclusions (e.g. ComponentTest excluding `:exunit_stale` while tests are
  being written).
  """
  @spec task_excluded_analyzers(map() | nil) :: [atom()]
  def task_excluded_analyzers(nil), do: []

  def task_excluded_analyzers(task) do
    module = task.session_type

    if module && function_exported?(module, :excluded_analyzers, 0) do
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

  Per-analyzer file scope is config-driven: credo in `:block_all` runs
  project-wide (no file path args, all credo problems cleared before
  re-insert); other modes and other analyzers stay scoped to the
  changed files of this turn.
  """
  @spec run_analyzers(Scope.t(), [atom()], [map()], map(), keyword()) :: :ok
  def run_analyzers(scope, analyzers, changed_files, config \\ %{}, opts \\ [])
  def run_analyzers(_scope, [], _changed_files, _config, _opts), do: :ok

  def run_analyzers(scope, analyzers, changed_files, config, opts) do
    run_analyzer_set(scope, analyzers, changed_files, config, opts)
    :ok
  end

  # -- Internal analyzer execution --

  defp run_analyzer_set(_scope, [], _files, _config, _opts), do: []

  defp run_analyzer_set(scope, analyzers, files, config, opts) do
    component_map = build_component_map(files)
    file_paths = Enum.map(files, & &1.path)

    {static_analyzers, validators} = split_analyzers(analyzers)

    all_problems =
      (run_static_analyzers(scope, static_analyzers, file_paths, config, opts) ++
         run_validators(scope, validators, files))
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
      runner_opts = [files: analyzer_files] |> with_test_output(atom, opts)
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

  # Spex-only escape hatch: cassette-backed tests inject a pre-recorded
  # JSON file at `:credo_output_file` so the analyzer reads it instead of
  # spawning `mix credo`. Mirrors `compile_output_file` /
  # `exunit_output_file` / `spex_output_file` already on the runner
  # analyzers. Lets criterion 5100 etc. exercise the credo block path
  # without losing the race against FileWatcherServer.
  defp with_test_output(runner_opts, :credo, validation_opts) do
    case Keyword.get(validation_opts, :credo_output_file) do
      nil -> runner_opts
      path -> Keyword.put(runner_opts, :output_file, path)
    end
  end

  defp with_test_output(runner_opts, _atom, _opts), do: runner_opts

  defp log_analyzer_success(atom, problems, analyzer_files, ms) do
    file_count = if is_nil(analyzer_files), do: "all", else: Integer.to_string(length(analyzer_files))

    Logger.info(
      "[Pipeline] #{atom}: #{length(problems)} problem(s) on #{file_count} file(s) (#{ms}ms)"
    )
  end

  # Project-wide credo, whatever its mode. `nil` tells the credo analyzer to
  # omit file-path args so `mix credo` scans every file under the configured
  # paths. All other static analyzers stay scoped to changed files.
  #
  # This used to key on `%{credo: :block_all}`, which was the older policy:
  # the mode decided what credo *looked at*. It decides what credo *blocks on*
  # now — `Validation.request_for/3` says so, and `apply_mode/4` does the
  # scoping at decision time instead. Under `:block_changed` a violation
  # outside the turn's files is meant to be found and recorded as advisory,
  # which cannot happen if the scan never reaches it.
  #
  # The stop hook does not arrive here for credo — `run_pipeline/5` routes it
  # to the subprocess set first — so this is a contradiction nobody was
  # executing. Left in place rather than deleted because a caller that does
  # reach it should get the current policy, not the one from two changes ago.
  defp files_for_analyzer(:credo, _file_paths, _config), do: nil
  defp files_for_analyzer(_atom, file_paths, _config), do: file_paths

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
    fun = &spec_document_type/2

    files
    |> Enum.filter(&(&1.role in [:spec, :review]))
    |> Enum.flat_map(&validate_document(scope, &1, "spec_validation", fun))
  end

  defp run_validator(scope, :validate_qa, files) do
    fun = &qa_document_type/2

    files
    |> Enum.filter(&(&1.role in [:qa_brief, :qa_result]))
    |> Enum.flat_map(&validate_document(scope, &1, "qa_validation", fun))
  end

  # BDD specs are .exs files — the compile step catches syntax errors and
  # RequirementCalculator handles runtime (spex passing) validation.
  defp run_validator(_scope, :validate_bdd, _files), do: []

  defp run_validator(_scope, validator, _files) do
    Logger.warning("[Pipeline] Unknown validator: #{validator}")
    []
  end

  defp validate_document(%Scope{environment: env} = scope, file, source, document_type_fn) do
    case Environments.read_file(env, file.path) do
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
    strict? = strict_for_source?(scope, source)

    case Documents.create_dynamic_document(content, document_type, strict: strict?) do
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

  # `require_specs == false` only loosens spec-file validation, not QA
  # artifact validation. QA briefs/results have their own analyzer field
  # (`qa_validation`) and stay strict whenever they run.
  defp strict_for_source?(scope, "spec_validation"),
    do: CodeMySpec.Configurations.require_specs?(scope)

  defp strict_for_source?(_scope, _source), do: true

  defp spec_document_type(%{role: :review}, _content), do: "design_review"
  defp spec_document_type(_file, content), do: document_type_from_content(content)

  defp qa_document_type(%{role: :qa_brief}, _content), do: "qa_story_brief"
  defp qa_document_type(%{role: :qa_result}, _content), do: "qa_result"

  # Mirrors FileSync.document_type_from_content/1 (kept private there).
  # CRLF → LF first so a Windows-written `## Type\r` still matches; otherwise
  # the type resolves to the default "spec" definition and the wrong section
  # set is enforced.
  defp document_type_from_content(content) do
    type_section =
      content
      |> String.replace("\r\n", "\n")
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

  defp split_analyzers(analyzers) do
    Enum.split_with(analyzers, fn atom ->
      atom in [:credo, :sobelow, :spec_alignment]
    end)
  end

  @analyzer_source_map %{
    credo: "credo",
    sobelow: "sobelow",
    spec_alignment: "spec_alignment",
    validate_spec: "spec_validation",
    validate_bdd: "spec_validation",
    validate_qa: "qa_validation"
  }

  # Each entry pairs a problem `source` (the string written into the DB)
  # with the file scope to clear before re-inserting. credo in
  # `:block_all` clears project-wide (`:all`); everything else clears
  # only the changed files of this turn.
  defp source_scopes_for(static_analyzers, validators, file_paths, config) do
    static_pairs =
      Enum.map(static_analyzers, fn atom ->
        source = Map.get(@analyzer_source_map, atom, Atom.to_string(atom))
        {source, scope_for_source(atom, file_paths, config)}
      end)

    validator_pairs =
      Enum.map(validators, fn validator ->
        source = Map.get(@analyzer_source_map, validator, Atom.to_string(validator))
        {source, file_paths}
      end)

    (static_pairs ++ validator_pairs)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp scope_for_source(:credo, _file_paths, %{credo: :block_all}), do: :all
  defp scope_for_source(_atom, file_paths, _config), do: file_paths

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
