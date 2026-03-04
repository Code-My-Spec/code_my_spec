defmodule CodeMySpec.ProjectCoordinator do
  @moduledoc """
  Central coordinator for project requirements, dependency chains, and orchestration.

  Provides:
  - Requirement sync and next-actionable traversal
  - Dependency-chain traversal (build chain, find next ready)
  - Component collection and actionable-work discovery
  - Prompt/problem file generation and orchestration for task modules
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Components.DependencyTree
  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectCoordinator.ComponentAnalyzer
  alias CodeMySpec.ProjectCoordinator.NextActionable
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Tests.TestRun
  alias CodeMySpec.Users.Scope

  @type component_list :: [Component.t()]
  @type file_list :: [String.t()]

  @status_dir CodeMySpec.Paths.status_dir()
  @container_types ["context", "coordination_context", "live_context"]

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
  Returns `{:ok, %Requirement{}}` with a `satisfied_by` task module, `:complete`,
  or `{:error, reason}` if a requirement is stuck with no actionable descent.
  """
  @spec get_next_actions(Scope.t()) :: {:ok, Requirement.t()} | :complete | {:error, String.t()}
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
  # Component Collection & Actionable Discovery
  # ============================================================================

  @doc """
  Collect a component and its descendants for container types.
  Non-container types return just the component itself.
  """
  @spec collect_components(any(), map()) :: [map()]
  def collect_components(scope, component) do
    if component.type in @container_types do
      children = ComponentRepository.list_all_descendants(scope, component.id)
      Logger.info("[ProjectCoordinator] #{component.module_name}: collected #{length(children)} descendants")
      [component | children]
    else
      Logger.info("[ProjectCoordinator] #{component.module_name}: leaf component (#{component.type})")
      [component]
    end
  end

  @doc """
  Find all actionable {component, task_module, definitions} tuples across components.

  Uses `Requirements.next_actionable/2` to find unsatisfied requirements with met
  prerequisites. Components with all requirements satisfied are skipped.
  """
  @spec find_actionable(any(), [map()]) :: [
          %{component: map(), task_module: module(), definitions: [map()]}
        ]
  def find_actionable(scope, components) do
    actionable =
      Enum.flat_map(components, fn component ->
        scope
        |> Requirements.next_actionable(component)
        |> Enum.map(fn {task_module, definitions} ->
          %{component: component, task_module: task_module, definitions: definitions}
        end)
      end)

    if actionable == [] do
      Logger.info("[ProjectCoordinator] No actionable work found across #{length(components)} components")
    else
      summary =
        Enum.map_join(actionable, ", ", fn %{component: c, task_module: tm} ->
          "#{c.module_name}→#{task_module_suffix(tm)}"
        end)

      Logger.info("[ProjectCoordinator] Actionable: #{summary}")
    end

    actionable
  end

  @doc """
  Find remaining unsatisfied requirements across components (including meta requirements).
  Used to check if all work is truly done.
  """
  @spec find_remaining(any(), [map()]) :: [%{component: map(), name: String.t()}]
  def find_remaining(_scope, components) do
    remaining =
      Enum.flat_map(components, fn component ->
        (component.requirements || [])
        |> Enum.reject(& &1.satisfied)
        |> Enum.map(fn req -> %{component: component, name: req.name} end)
      end)

    if remaining == [] do
      Logger.info("[ProjectCoordinator] All requirements satisfied across #{length(components)} components")
    else
      summary =
        Enum.map_join(remaining, ", ", fn %{component: c, name: n} ->
          "#{c.module_name}:#{n}"
        end)

      Logger.info("[ProjectCoordinator] Remaining (#{length(remaining)}): #{summary}")
    end

    remaining
  end

  # ============================================================================
  # Prompt File Generation & Orchestration
  # ============================================================================

  @doc """
  Generate prompt files for actionable work items.

  For each actionable item, calls the task module's `command/2` to generate
  the prompt content, writes it to the status directory, and returns metadata.
  """
  @spec generate_prompt_files(any(), map(), [map()], String.t()) :: {:ok, [map()]}
  def generate_prompt_files(scope, session, actionable, status_dir) do
    Logger.info("[ProjectCoordinator] Generating #{length(actionable)} prompt files in #{status_dir}")

    prompt_files =
      Enum.map(actionable, fn %{component: component, task_module: task_module} ->
        child_session = %{component: component, project: session.project}
        {:ok, prompt_content} = task_module.command(scope, child_session)

        safe_name = safe_filename(component.module_name)
        suffix = task_module_suffix(task_module)
        file_path = "#{status_dir}/#{safe_name}_#{suffix}.md"

        :ok = Environments.write_file(scope.environment, file_path, prompt_content)
        Logger.info("[ProjectCoordinator]   #{suffix} → #{file_path}")

        %{
          component: component,
          task_module: task_module,
          file_path: file_path,
          suffix: suffix
        }
      end)

    {:ok, prompt_files}
  end

  @doc """
  Build orchestration markdown listing prompt files with instructions.
  """
  @spec build_orchestration_prompt(map(), [map()], String.t()) :: String.t()
  def build_orchestration_prompt(root_component, prompt_files, _status_dir) do
    if Enum.empty?(prompt_files) do
      """
      # #{root_component.name}: All Requirements Satisfied

      All requirements for this component (and its children) are satisfied.
      No further action required.
      """
    else
      file_list = format_prompt_file_list(prompt_files)

      """
      # Development: #{root_component.name}

      The requirement graph has identified the following actionable work.
      Complete each task by reading the prompt file and invoking the appropriate subagent.

      ## Prompt Files

      #{file_list}

      ## Subagent Usage

      Invoke the appropriate subagent for each prompt file:

      - For spec prompts: `@"CodeMySpec:spec-writer (agent)"`
      - For design review prompts: `@"CodeMySpec:spec-writer (agent)"`
      - For test prompts: `@"CodeMySpec:test-writer (agent)"`
      - For code prompts: `@"CodeMySpec:code-writer (agent)"`

      ## Workflow

      1. Complete all tasks listed above
      2. **Stop the session** — end your turn so the stop hook can validate your work
      3. The stop hook will check your progress and provide instructions for the next batch
      4. If the hook blocks the stop, follow its feedback and repeat from step 1

      **Important:** You must stop after completing the current batch. Do not attempt to
      continue to the next batch on your own — the stop hook uses the requirement graph
      to generate the prompt files you need for each subsequent batch.
      """
    end
  end

  @doc """
  Derive a status directory from a component's module_name.

  MetricFlow.Accounts → .code_my_spec/status/metric_flow/accounts
  """
  @spec component_status_dir(map()) :: String.t()
  def component_status_dir(component) do
    parts =
      component.module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join([@status_dir | dir_parts] ++ [dirname])
  end

  @doc """
  Remove the entire status directory for a component.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec cleanup_status_directory(String.t(), String.t() | nil) :: :ok
  def cleanup_status_directory(status_dir, working_dir) do
    dir = resolve_dir(status_dir, working_dir)

    if File.exists?(dir) and File.dir?(dir) do
      File.rm_rf(dir)
    end

    :ok
  end

  @doc """
  Default orchestrate implementation for task modules.

  Always writes the prompt file (via command), then checks completeness
  (via evaluate). If incomplete, also writes the feedback to a problems file.

  Returns `{:ok, %{prompt_path, complete, problem_path, orchestration_prompt}}`.

  ## Options

  - `:status_dir` — override status directory (defaults to component-derived path)
  """
  @spec default_orchestrate(module(), any(), map(), keyword()) :: {:ok, map()}
  def default_orchestrate(task_module, scope, session, opts) do
    component = session.component
    module_name = component.module_name
    status_dir = Keyword.get_lazy(opts, :status_dir, fn -> component_status_dir(component) end)
    safe_name = safe_filename(module_name)
    suffix = task_module_suffix(task_module)

    Logger.info("[ProjectCoordinator] #{suffix} for #{module_name}: generating prompt")

    prompt_path = "#{status_dir}/#{safe_name}_#{suffix}.md"
    problem_path = "#{status_dir}/#{safe_name}_#{suffix}_problems.md"

    # Check completeness — write prompt + problems only if incomplete
    {complete, _problems} =
      case task_module.evaluate(scope, session) do
        {:ok, :valid} ->
          Logger.info("[ProjectCoordinator] #{suffix} for #{module_name}: complete")
          cwd = scope.environment && scope.environment.cwd
          cleanup_file(prompt_path, cwd)
          cleanup_file(problem_path, cwd)
          {true, nil}

        {:ok, :invalid, feedback} ->
          Logger.info("[ProjectCoordinator] #{suffix} for #{module_name}: incomplete, writing prompt")
          {:ok, prompt_content} = task_module.command(scope, session)
          :ok = Environments.write_file(scope.environment, prompt_path, prompt_content)
          :ok = Environments.write_file(scope.environment, problem_path, feedback)
          {false, feedback}
      end

    # Build orchestration checklist line — this is the initial command pass,
    # so point to the prompt file (the work to do), not the problems file.
    orchestration_prompt =
      if complete do
        "[x] #{suffix} for #{module_name} complete."
      else
        "[ ] #{suffix} for #{module_name}: read prompt at `#{prompt_path}`"
      end

    {:ok,
     %{
       prompt_path: prompt_path,
       complete: complete,
       problem_path: problem_path,
       orchestration_prompt: orchestration_prompt
     }}
  end

  @doc """
  Evaluate-side counterpart to `default_orchestrate/4`.

  Only calls `evaluate/3` (not `command/3`). If incomplete, writes the feedback
  to a problems file. If complete, cleans up the problems file.

  Returns `{:ok, %{complete, problem_path, orchestration_prompt}}`.

  ## Options

  - `:status_dir` — override status directory (defaults to component-derived path)
  """
  @spec default_orchestrate_evaluate(module(), any(), map(), keyword()) :: {:ok, map()}
  def default_orchestrate_evaluate(task_module, scope, session, opts) do
    component = session.component
    module_name = component.module_name
    status_dir = Keyword.get_lazy(opts, :status_dir, fn -> component_status_dir(component) end)
    safe_name = safe_filename(module_name)
    suffix = task_module_suffix(task_module)

    prompt_path = "#{status_dir}/#{safe_name}_#{suffix}.md"
    problem_path = "#{status_dir}/#{safe_name}_#{suffix}_problems.md"

    {complete, _problems} =
      case task_module.evaluate(scope, session) do
        {:ok, :valid} ->
          Logger.info("[ProjectCoordinator] #{suffix} evaluate for #{module_name}: complete")
          # Clean up prompt and problems files
          cwd = scope.environment && scope.environment.cwd
          cleanup_file(prompt_path, cwd)
          cleanup_file(problem_path, cwd)
          {true, nil}

        {:ok, :invalid, feedback} ->
          Logger.info(
            "[ProjectCoordinator] #{suffix} evaluate for #{module_name}: incomplete, writing problems"
          )

          :ok = Environments.write_file(scope.environment, problem_path, feedback)
          {false, feedback}
      end

    orchestration_prompt =
      if complete do
        "[x] #{suffix} for #{module_name} complete."
      else
        "[ ] #{suffix} for #{module_name} is not complete. Fix the problems at #{problem_path}"
      end

    {:ok,
     %{
       complete: complete,
       problem_path: problem_path,
       orchestration_prompt: orchestration_prompt
     }}
  end

  @doc """
  Write a prompt file for a component/task and return metadata.
  """
  @spec write_prompt_file(any(), map(), module(), String.t(), keyword()) :: map()
  def write_prompt_file(scope, component, task_module, prompt_content, opts) do
    status_dir = Keyword.fetch!(opts, :status_dir)
    safe_name = safe_filename(component.module_name)
    suffix = task_module_suffix(task_module)
    file_path = "#{status_dir}/#{safe_name}_#{suffix}.md"

    :ok = Environments.write_file(scope.environment, file_path, prompt_content)

    %{
      component: component,
      task_module: task_module,
      file_path: file_path,
      suffix: suffix
    }
  end

  @doc """
  Convert a module name to a safe filename.
  """
  @spec safe_filename(String.t()) :: String.t()
  def safe_filename(module_name) do
    module_name
    |> String.replace(".", "_")
    |> String.downcase()
  end

  @doc """
  Derive a suffix from a task module name.

  CodeMySpec.AgentTasks.ComponentSpec → "component_spec"
  """
  @spec task_module_suffix(module()) :: String.t()
  def task_module_suffix(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  @doc """
  Format prompt files into a markdown checklist grouped by component.
  """
  def format_prompt_file_list(prompt_files) do
    prompt_files
    |> Enum.group_by(fn pf -> pf.component.id end)
    |> Enum.map_join("\n\n", fn {_id, files} ->
      component = hd(files).component

      file_entries =
        Enum.map_join(files, "\n", fn pf ->
          agent = agent_for_suffix(pf.suffix)
          "  - [ ] `#{pf.file_path}` → #{agent}"
        end)

      "- **#{component.name}** (#{component.type})\n#{file_entries}"
    end)
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

  defp resolve_dir(status_dir, nil), do: status_dir
  defp resolve_dir(status_dir, working_dir), do: Path.join(working_dir, status_dir)

  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup_file(relative_path, nil) do
    File.rm(relative_path)
    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup_file(relative_path, working_dir) do
    File.rm(Path.join(working_dir, relative_path))
    :ok
  end

  defp agent_for_suffix(suffix) do
    cond do
      String.contains?(suffix, "spec") -> "`@\"CodeMySpec:spec-writer (agent)\"`"
      String.contains?(suffix, "test") -> "`@\"CodeMySpec:test-writer (agent)\"`"
      String.contains?(suffix, "code") -> "`@\"CodeMySpec:code-writer (agent)\"`"
      String.contains?(suffix, "review") -> "`@\"CodeMySpec:spec-writer (agent)\"`"
      true -> "appropriate subagent"
    end
  end
end
