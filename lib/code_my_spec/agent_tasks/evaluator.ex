defmodule CodeMySpec.AgentTasks.Evaluator do
  @moduledoc """
  Unified evaluation entry point for agent tasks.

  Both `EvaluateTask` (MCP tool) and `TaskEvaluator` (StopHook) delegate here.
  The flow:

  1. Sync files from filesystem → DB (safety net; FileWatcherServer handles real-time)
  2. Run optional `before_evaluate/2` callback on the task module (side effects)
  3. Check requirement satisfaction via RequirementCalculator (single source of truth)
  4. Format feedback from unsatisfied requirement details + problem feedback

  Task modules that need custom evaluation logic (StartImplementation, ProjectSetup)
  can still implement `evaluate/2` — the caller falls back to that when present.
  """

  require Logger

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.Components
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.Stories.StoriesRepository
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

  @doc """
  Evaluate a task: sync files, run side effects, check requirement.

  Returns `{:ok, :valid}` or `{:ok, :invalid, feedback}`.
  """
  @spec evaluate(Scope.t(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, String.t()}
  def evaluate(%Scope{} = scope, task, opts \\ []) do
    task_module = task.session_type

    # Step 1: Sync files. Callers that just synced (stop-hook validation,
    # the analysis Reconciler) pass `sync: false` — a second full-tree walk
    # is wasted work, and its missing-files problem sweep would race the
    # problems the caller just reconciled.
    if Keyword.get(opts, :sync, true), do: sync_files(scope)

    # Step 2: Optional before_evaluate callback (side effects like proposal execution)
    run_before_evaluate(task_module, scope, task)

    # Step 3: Check requirement via RequirementCalculator
    check_requirement(scope, task)
  rescue
    e ->
      {:error, "Evaluation failed: #{Exception.message(e)}"}
  end

  @doc """
  Check whether a task module should use the unified evaluator or its own evaluate/2.

  Returns true for task modules that have custom evaluate logic that can't be
  expressed as a RequirementCalculator check (e.g., StartImplementation checks
  next_actionable; ProjectSetup runs setup steps).
  """
  @spec has_custom_evaluate?(module()) :: boolean()
  def has_custom_evaluate?(module) do
    # These modules have evaluate/2 that does something the calculator can't
    module in custom_evaluate_modules()
  end

  @doc """
  Modules with genuinely custom evaluation logic — their `evaluate/2`
  produces a done signal that can't be expressed as a `RequirementCalculator`
  check.
  """
  def custom_evaluate_modules do
    [
      CodeMySpec.AgentTasks.StartImplementation,
      CodeMySpec.AgentTasks.ProjectSetup,
      CodeMySpec.AgentTasks.QaApp,
      CodeMySpec.AgentTasks.QaSetup,
      CodeMySpec.AgentTasks.QaIntegrationPlan,
      CodeMySpec.AgentTasks.Init,
      CodeMySpec.AgentTasks.DesignUi,
      CodeMySpec.AgentTasks.ResearchTopic,
      CodeMySpec.AgentTasks.ArchitectureDesign,
      CodeMySpec.AgentTasks.QaStory,
      CodeMySpec.AgentTasks.TriageIssues,
      CodeMySpec.AgentTasks.FixIssues,
      CodeMySpec.AgentTasks.WriteBddSpecs,
      # The specs-passing gate SETS `specs_ready` as a side effect of
      # passing. The calculator's `:field_true` check can only read the
      # latch, so without this the stop hook would evaluate the field,
      # find it false, and block forever — nothing would ever flip it.
      CodeMySpec.AgentTasks.FixBddSpecs,
      # And Three Amigos, for exactly the reason above. Its gate SETS
      # `three_amigos_sealed` as a side effect of passing, and the requirement
      # reads the seal — so without this the calculator evaluates the latch,
      # finds it false, and nothing ever flips it. The task reports "ready to
      # seal but has not been sealed" forever, which is a true sentence and an
      # unreachable state.
      CodeMySpec.AgentTasks.ThreeAmigos
    ]
  end

  # -- File Sync --

  defp sync_files(%Scope{cwd: nil}), do: :ok

  defp sync_files(%Scope{cwd: cwd} = scope) do
    # `embed: false` — the stop-hook evaluator fires on every turn and
    # has no business re-embedding the framework knowledge corpus or
    # re-projecting hex docs each time. `FileWatcherServer`'s boot pass
    # + mix.lock-poll keep the embedding store fresh during a session;
    # the explicit `sync_project` MCP tool is the manual-full-sync
    # surface that opts back into the embed pre-pass.
    case FileSync.sync(scope, base_dir: cwd, embed: false) do
      {:ok, file_result} ->
        FileComponentSync.sync_from_files(scope,
          base_dir: cwd,
          changed_paths: file_result.changed_paths
        )

        :ok

      # Nothing was scanned, so nothing changed, so there is nothing to project
      # into components. `FileSync` has already said why at `:error`. Evaluation
      # continues against the rows already recorded — which is the point: they
      # are the last thing that was actually observed, and the alternative that
      # used to happen here was deleting them.
      {:error, _reason} ->
        :ok
    end
  end

  # -- Before Evaluate --

  defp run_before_evaluate(nil, _scope, _task), do: :ok

  defp run_before_evaluate(module, scope, task) do
    if function_exported?(module, :before_evaluate, 2) do
      Logger.info("[Evaluator] Running before_evaluate for #{inspect(module)}")
      module.before_evaluate(scope, task)
    end

    :ok
  end

  # -- Requirement Check --

  defp check_requirement(scope, task) do
    with {:ok, {entity, entity_type}} <- resolve_entity(scope, task),
         {:ok, definition} <- find_definition(scope, entity_type, task.requirement_name, entity) do
      files = load_files(scope, entity, entity_type)
      result = RequirementCalculator.compute_one(scope, entity, definition, files)

      if result.satisfied do
        {:ok, :valid}
      else
        feedback = format_feedback(scope, entity, entity_type, result, definition)
        {:ok, :invalid, feedback}
      end
    end
  end

  defp resolve_entity(scope, task) do
    cond do
      task.component_id ->
        wrap_entity(Components.get_component(scope, task.component_id), :component)

      task.story_id ->
        wrap_entity(StoriesRepository.get_story(scope, task.story_id), :story)

      task.project_id || scope.active_project ->
        {:ok, {scope.active_project, :project}}

      true ->
        {:error, "Cannot resolve entity from task — no component_id, story_id, or project"}
    end
  end

  defp wrap_entity(nil, _type), do: {:error, :entity_missing}
  defp wrap_entity(entity, type), do: {:ok, {entity, type}}

  defp find_definition(scope, :component, requirement_name, entity) do
    # First try the component's own type template
    definitions = RequirementsRegistry.get_requirements_for_type(entity.type)

    case find_by_name(definitions, requirement_name) do
      {:ok, _} = found ->
        found

      {:error, _} ->
        # If not found and component has a parent, check parent template's :child nodes.
        # A schema child of a context gets :child requirements from the context template.
        case entity.parent_component_id &&
               Components.get_component(scope, entity.parent_component_id) do
          %_{} = parent ->
            parent_template = RequirementsRegistry.get_graph_template(parent.type)
            child_defs = Enum.filter(parent_template, &(&1.node_scope == :child))
            find_by_name(child_defs, requirement_name)

          _ ->
            {:error, "No requirement definition found with name: #{requirement_name}"}
        end
    end
  end

  defp find_definition(_scope, :story, requirement_name, _entity) do
    find_by_name(RequirementDefinitionData.story_requirements(), requirement_name)
  end

  defp find_definition(_scope, :project, requirement_name, _entity) do
    find_by_name(RequirementDefinitionData.project_requirements(), requirement_name)
  end

  defp find_by_name(definitions, name) do
    case Enum.find(definitions, &(&1.name == name)) do
      nil -> {:error, "No requirement definition found with name: #{name}"}
      definition -> {:ok, definition}
    end
  end

  defp load_files(scope, entity, :component) do
    CodeMySpec.Files.list_component_files(scope, entity.id)
  end

  defp load_files(scope, entity, :story) do
    CodeMySpec.Files.list_story_files(scope, entity.id)
  end

  defp load_files(scope, _entity, :project) do
    CodeMySpec.Files.list_files(scope)
  end

  # -- Feedback Formatting --

  defp format_feedback(scope, entity, :component, result, _definition) do
    req_feedback =
      RequirementsFormatter.format_unsatisfied(
        [
          struct(
            CodeMySpec.Requirements.Requirement,
            Map.merge(result, %{description: result.details[:reason] || "unsatisfied"})
          )
        ],
        context: "Requirement not met:"
      )

    project = scope.active_project
    problem_feedback = problem_feedback_for(scope, entity, :component, project)
    join_feedback(req_feedback, problem_feedback)
  end

  defp format_feedback(_scope, _entity, _type, result, _definition) do
    reason = MapAccess.get(result.details, :reason, "Requirement not satisfied")
    "Requirement not met: #{reason}"
  end

  defp problem_feedback_for(scope, component, :component, project) do
    # Determine which problem feedback to use based on the task artifact type
    # For now, include all problems for the component
    code_feedback = ProblemFeedback.for_code_task(scope, component, project)
    spec_feedback = ProblemFeedback.for_spec_task(scope, component, project)

    case {code_feedback, spec_feedback} do
      {nil, nil} -> nil
      {code, nil} -> code
      {nil, spec} -> spec
      {code, spec} -> "#{code}\n\n#{spec}"
    end
  end

  defp join_feedback(req, nil), do: req
  defp join_feedback(req, problem), do: "#{req}\n\n#{problem}"
end
