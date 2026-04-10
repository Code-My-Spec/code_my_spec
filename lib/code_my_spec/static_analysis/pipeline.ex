defmodule CodeMySpec.StaticAnalysis.Pipeline do
  @moduledoc """
  Runs compilation and static analysis during stop hooks.

  Decision flow:
  1. Compiler always runs (blocks on errors)
  2. Classify changed files by role
  3. File roles determine which analyzers/validators run
  4. Task module can override via analyzers/0 callback
  5. Persist problems so RequirementCalculator sees them

  ## Tuning

  The `@role_analyzers` map is the primary tuning surface. It maps file roles
  to the analyzers that should run when files of that role change. Task modules
  can override this entirely by implementing `analyzers/0`.
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
    implementation: [:credo],
    test: [:credo],
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

  @doc """
  Run the full analysis pipeline: compile, then role-based analyzers.

  Returns:
  - `{:ok, :continue}` — all clear
  - `{:ok, :continue, advisory}` — passed but out-of-scope problems found
  - `{:error, reason}` — compiler errors, must fix before continuing
  """
  @spec run_pipeline(Scope.t(), map() | nil, keyword()) ::
          {:ok, :continue}
          | {:ok, :continue, String.t()}
          | {:error, String.t()}
  def run_pipeline(%Scope{} = scope, task, _opts \\ []) do
    pipeline_start = System.monotonic_time(:millisecond)

    result =
      with {:ok, :compiled} <- compile_and_persist(scope) do
        run_analyzers_for_task(scope, task)
      end

    elapsed = System.monotonic_time(:millisecond) - pipeline_start
    log_pipeline_result(result, elapsed)
    result
  end

  # -- Compilation (always runs, blocks on errors) --

  defp compile_and_persist(%Scope{cwd: nil}), do: {:ok, :compiled}

  defp compile_and_persist(%Scope{cwd: cwd} = scope) do
    start = System.monotonic_time(:millisecond)

    result = Compile.execute(cwd: cwd)
    diagnostics = result.data.compiler_results

    # Convert diagnostics to Problem structs
    problems =
      diagnostics
      |> Enum.map(&ProblemConverter.from_compiler/1)
      |> Enum.map(&%{&1 | project_id: scope.active_project_id})

    # Clear old compiler problems, persist new ones
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
      {:ok, :compiled}
    end
  end

  # -- Role-based analyzer dispatch --

  defp run_analyzers_for_task(_scope, nil) do
    Logger.info("[Pipeline] No task, skipping analyzers")
    {:ok, :continue}
  end

  defp run_analyzers_for_task(_scope, %{started_at: nil}) do
    Logger.info("[Pipeline] Task has no started_at, skipping analyzers")
    {:ok, :continue}
  end

  defp run_analyzers_for_task(scope, task) do
    # Get all files changed during this task
    changed_files = Files.changed_since(scope, task.started_at)

    if changed_files == [] do
      Logger.info("[Pipeline] No files changed during task")
      {:ok, :continue}
    else
      # Log the role breakdown
      role_summary = format_role_summary(changed_files)
      Logger.info("[Pipeline] Changed files: #{role_summary}")

      # Split in-scope vs out-of-scope
      {in_scope, out_of_scope} = split_scope(changed_files, task)

      if out_of_scope != [] do
        Logger.info(
          "[Pipeline] Scope: #{length(in_scope)} in-scope, #{length(out_of_scope)} out-of-scope"
        )
      end

      # Determine which analyzers to run
      {analyzers, source} = resolve_analyzers_with_source(task, in_scope)

      Logger.info("[Pipeline] Analyzers: #{inspect(analyzers)} (#{source})")

      # Run analyzers on in-scope files
      _in_scope_problems = run_analyzer_set(scope, analyzers, in_scope, "in-scope")

      # Run analyzers on out-of-scope files too
      out_of_scope_problems =
        if out_of_scope != [] do
          out_analyzers = analyzers_for_roles(out_of_scope)

          if out_analyzers != [] do
            Logger.info("[Pipeline] Out-of-scope analyzers: #{inspect(out_analyzers)}")
          end

          run_analyzer_set(scope, out_analyzers, out_of_scope, "out-of-scope")
        else
          []
        end

      # Build advisory for out-of-scope problems
      advisory = format_out_of_scope_advisory(out_of_scope_problems)

      case advisory do
        nil -> {:ok, :continue}
        text -> {:ok, :continue, text}
      end
    end
  end

  # -- Analyzer resolution --

  defp resolve_analyzers_with_source(task, changed_files) do
    module = task.session_type

    if module && function_exported?(module, :analyzers, 0) do
      type_name = module |> Atom.to_string() |> String.split(".") |> List.last()
      {module.analyzers(), "override from #{type_name}.analyzers/0"}
    else
      {analyzers_for_roles(changed_files), "from file roles"}
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

  defp run_analyzer_set(_scope, [], _files, _label), do: []

  defp run_analyzer_set(scope, analyzers, files, label) do
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

    # Persist: clear old problems for these files+sources, insert new
    persist_problems(scope, all_problems, file_paths)

    if all_problems != [] do
      by_source =
        all_problems
        |> Enum.group_by(& &1.source)
        |> Enum.map_join(", ", fn {source, probs} -> "#{source}(#{length(probs)})" end)

      Logger.info("[Pipeline] #{label}: persisted #{length(all_problems)} problem(s) — #{by_source}")
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

  # -- Problem persistence --

  defp persist_problems(_scope, [], _file_paths), do: :ok

  defp persist_problems(scope, problems, file_paths) do
    # Clear old problems for each source we're about to replace
    sources = problems |> Enum.map(& &1.source) |> Enum.uniq()

    Enum.each(sources, fn source ->
      Problems.clear_problems_for_source(scope, [source: source], file_paths)
    end)

    Problems.create_problems(scope, problems)
  end

  # -- Scope splitting --

  defp split_scope(changed_files, task) do
    Enum.split_with(changed_files, fn file ->
      cond do
        task.component_id && file.component_id ->
          file.component_id == task.component_id

        task.story_id && file.story_id ->
          file.story_id == task.story_id

        true ->
          # No scoping info on task or file — treat as in-scope
          true
      end
    end)
  end

  # -- Logging helpers --

  defp format_role_summary(files) do
    files
    |> Enum.group_by(& &1.role)
    |> Enum.map_join(", ", fn {role, role_files} ->
      "#{role}(#{length(role_files)})"
    end)
  end

  defp log_pipeline_result({:error, _reason}, elapsed) do
    Logger.info("[Pipeline] Done in #{elapsed}ms — BLOCKED (compiler errors)")
  end

  defp log_pipeline_result({:ok, :continue, _advisory}, elapsed) do
    Logger.info("[Pipeline] Done in #{elapsed}ms — passed with advisory")
  end

  defp log_pipeline_result({:ok, :continue}, elapsed) do
    Logger.info("[Pipeline] Done in #{elapsed}ms — passed")
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

  defp format_out_of_scope_advisory([]), do: nil

  defp format_out_of_scope_advisory(problems) do
    error_count = Enum.count(problems, &(&1.severity == :error))
    warning_count = Enum.count(problems, &(&1.severity == :warning))

    counts =
      [
        if(error_count > 0, do: "#{error_count} error(s)"),
        if(warning_count > 0, do: "#{warning_count} warning(s)")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    if counts == "" do
      nil
    else
      "Note: Changes to files outside this task's scope have #{counts}. " <>
        "These have been recorded for their respective components."
    end
  end
end
