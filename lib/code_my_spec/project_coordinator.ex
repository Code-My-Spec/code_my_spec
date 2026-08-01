defmodule CodeMySpec.ProjectCoordinator do
  @moduledoc """
  Central coordinator for project requirements and orchestration.

  Provides:
  - Requirement sync via ComponentAnalyzer
  - Component collection and actionable-work discovery
  - Prompt/problem file generation and orchestration for task modules
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @tasks_dir CodeMySpec.Paths.tasks_dir()

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
    Logger.info(
      "[ProjectCoordinator] Generating #{length(actionable)} prompt files in #{status_dir}"
    )

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
  Derive a tasks directory from a component's module_name.

  MetricFlow.Accounts → .code_my_spec/tasks/metric_flow/accounts
  """
  @spec component_status_dir(map()) :: String.t()
  def component_status_dir(component) do
    parts =
      component.module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [dirname]} = Enum.split(parts, -1)
    Path.join([@tasks_dir | dir_parts] ++ [dirname])
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
  def default_orchestrate(task_module, scope, task, opts) do
    {module_name, status_dir} = resolve_task_identity(scope, task, opts)
    safe_name = safe_filename(module_name)
    suffix = task_module_suffix(task_module)

    Logger.info("[ProjectCoordinator] #{suffix} for #{module_name}: generating prompt")

    prompt_path = "#{status_dir}/#{safe_name}_#{suffix}.md"
    problem_path = "#{status_dir}/#{safe_name}_#{suffix}_problems.md"

    {complete, problems} =
      case task_module.evaluate(scope, task) do
        {:ok, :valid} ->
          Logger.info("[ProjectCoordinator] #{suffix} for #{module_name}: complete")
          cleanup_file(scope.environment, prompt_path)
          cleanup_file(scope.environment, problem_path)
          {true, nil}

        {:ok, :invalid, feedback} ->
          Logger.info(
            "[ProjectCoordinator] #{suffix} for #{module_name}: incomplete, writing prompt"
          )

          {:ok, prompt_content} = task_module.command(scope, task)
          :ok = Environments.write_file(scope.environment, prompt_path, prompt_content)
          :ok = Environments.write_file(scope.environment, problem_path, feedback)
          {false, feedback}
      end

    orchestration_prompt =
      cond do
        complete ->
          "[x] #{suffix} for #{module_name} complete."

        not is_nil(problems) ->
          "[ ] #{suffix} for #{module_name} has problems. " <>
            "Fix the problems at `#{problem_path}` (full spec at `#{prompt_path}`)"

        true ->
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
  def default_orchestrate_evaluate(task_module, scope, task, opts) do
    {module_name, status_dir} = resolve_task_identity(scope, task, opts)
    safe_name = safe_filename(module_name)
    suffix = task_module_suffix(task_module)

    prompt_path = "#{status_dir}/#{safe_name}_#{suffix}.md"
    problem_path = "#{status_dir}/#{safe_name}_#{suffix}_problems.md"

    {complete, _problems} =
      case task_module.evaluate(scope, task) do
        {:ok, :valid} ->
          Logger.info("[ProjectCoordinator] #{suffix} evaluate for #{module_name}: complete")
          # Clean up prompt and problems files
          cleanup_file(scope.environment, prompt_path)
          cleanup_file(scope.environment, problem_path)
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

  Uses only the last segment of the module name since the directory path
  already encodes the full module hierarchy.

  MetricFlow.Accounts.AccountRepository → "account_repository"
  """
  @spec safe_filename(String.t()) :: String.t()
  def safe_filename(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
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

  # Extracts module_name and status_dir from a session map.
  # Handles both component-scoped sessions (has :component) and
  # project-scoped sessions (only :project).
  defp resolve_task_identity(scope, task, opts) do
    case {Map.get(task, :component_id), Map.get(task, :component_module_name)} do
      {cid, _} when not is_nil(cid) ->
        component = Components.get_component!(scope, cid)

        status_dir =
          Keyword.get_lazy(opts, :status_dir, fn -> component_status_dir(component) end)

        {component.module_name, status_dir}

      {_, name} when is_binary(name) ->
        {name, Keyword.get(opts, :status_dir, @tasks_dir)}

      _ ->
        project = scope.active_project
        module_name = project.name
        status_dir = Keyword.get(opts, :status_dir, @tasks_dir)
        {module_name, status_dir}
    end
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

  # Deletes go through the same environment the writes did. They used to unwrap
  # `scope.environment.cwd` and hand the joined path to File.rm, which meant a
  # prompt written onto a sprite was deleted from whatever machine happened to
  # run the evaluation — so the prompt survived, and the agent kept being told
  # to redo work it had finished.
  defp cleanup_file(%Environment{} = env, relative_path) do
    Environments.delete_file(env, relative_path)
    :ok
  end

  # No environment means nothing here to clean up. Deleting through an
  # environment invented from this process's directory would remove a file
  # from the *server's* checkout.
  defp cleanup_file(nil, _relative_path) do
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
