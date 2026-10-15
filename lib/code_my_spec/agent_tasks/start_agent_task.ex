# Every `apply/3` here is the module's dynamic dispatch to a task module's
# `command/2` (see the note above `run_bootstrap_task/3`). One decision, so
# suppressed once for the file.
# credo:disable-for-this-file Credo.Check.Refactor.Apply
defmodule CodeMySpec.AgentTasks.StartAgentTask do
  @moduledoc """
  Start an agent task session by session type and generate its prompt.

  The skill/CLI route, beside the graph route (`start_task`). Except for
  bootstrap types, finds or creates the Claude Code Session, syncs the project's files incrementally, looks up
  the component or topic the type needs, and calls the task module's
  `command/2`. The prompt is prefixed with project context (docs location,
  decision records, architecture tools).

  Does no IO; returns `{:ok, prompt, sync_result}` or `{:error, reason}`.
  """

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Paths
  alias CodeMySpec.Qa
  alias CodeMySpec.Sessions
  alias CodeMySpec.Stories
  alias CodeMySpec.TaskOwner

  # Maps session type names to AgentTask modules. A function, not a module
  # attribute: an attribute would be a compile-time reference to every task
  # module and put this module in the app's compile cycle.
  def session_type_map do
    %{
      "develop_context" => AgentTasks.DevelopContext,
      "fix_all_bdd_specs" => AgentTasks.FixAllBddSpecs,
      "fix_bdd_specs" => AgentTasks.FixBddSpecs,
      "ready_for_qa" => AgentTasks.ReadyForQa,
      "develop_live_view" => AgentTasks.DevelopLiveView,
      "component_code" => AgentTasks.ComponentCode,
      "component_test" => AgentTasks.ComponentTest,
      "project_setup" => AgentTasks.ProjectSetup,
      "architecture_design" => AgentTasks.ArchitectureDesign,
      "code_generation" => AgentTasks.CodeGeneration,
      "write_bdd_specs" => AgentTasks.WriteBddSpecs,
      "story_interview" => AgentTasks.StoryInterview,
      "story_review" => AgentTasks.StoryInterview,
      "design_ui" => AgentTasks.DesignUi,
      "technical_strategy" => AgentTasks.TechnicalStrategy,
      "research_topic" => AgentTasks.ResearchTopic,
      "qa_app" => AgentTasks.QaApp,
      "qa_integration_plan" => AgentTasks.QaIntegrationPlan,
      "qa_journey_plan" => AgentTasks.QaJourney,
      "qa_journey_execute" => AgentTasks.QaJourney,
      "qa_setup" => AgentTasks.QaSetup,
      "qa_story" => AgentTasks.QaStory,
      "start_implementation" => AgentTasks.StartImplementation,
      "three_amigos" => AgentTasks.ThreeAmigos,
      "triage_issues" => AgentTasks.TriageIssues,
      "fix_issues" => AgentTasks.FixIssues,
      "spex_boundary_ready" => AgentTasks.SpexBoundaryReady,
      "persona_research" => AgentTasks.PersonaResearch,
      "release" => AgentTasks.Release,
      "init" => AgentTasks.Init,
      "issue_fix" => AgentTasks.IssueFix,
      "submit_story_issue" => AgentTasks.SubmitStoryIssue,
      # Created by `Agents.IssueWork`, not started here, but every module in
      # `Evaluator.custom_evaluate_modules/0` must be reachable from this map
      # (`ConsistencyTest`).
      "issue_qa" => AgentTasks.IssueQa,
      # Created by `Agents.IssueWork` once QA passes the fix, like `issue_qa`.
      "issue_promote" => AgentTasks.IssuePromote
    }
  end

  # Tasks that run without a project or config.yml
  @bootstrap_tasks ["project_setup", "init"]

  # Tasks that run a project-wide validation step (e.g. batch spex) before session creation
  @project_tasks ["start_implementation"]

  # Tasks that don't require a component/module_name
  @componentless_tasks [
    "project_setup",
    "story_interview",
    "story_review",
    "architecture_design",
    "code_generation",
    "write_bdd_specs",
    "design_ui",
    "fix_all_bdd_specs",
    "technical_strategy",
    "qa_app",
    "qa_journey_plan",
    "qa_journey_execute",
    "qa_integration_plan",
    "qa_setup",
    "triage_issues",
    "fix_issues",
    "spex_boundary_ready",
    "persona_research",
    # Project-wide: a release gathers what shipped across every story.
    "release"
  ]

  # Tasks that take a topic (passed as `module_name`) instead of a component.
  # `qa_story` and `three_amigos` take a story there, so the skill can start
  # against any story without the graph.
  @topic_tasks ["research_topic", "qa_story", "three_amigos"]

  def valid_types, do: Map.keys(session_type_map())
  def componentless_tasks, do: @componentless_tasks
  def bootstrap_tasks, do: @bootstrap_tasks
  def project_tasks, do: @project_tasks
  def topic_tasks, do: @topic_tasks

  @doc """
  Run the start agent task flow and return the prompt.
  Does not perform any IO - caller is responsible for output.

  ## Args

  - `:external_id` - Claude session ID (required)
  - `:session_type` - Type of agent task (required)
  - `:module_name` - Component module name (required for component tasks)

  ## Returns

  - `{:ok, prompt, sync_result}` on success
  - `{:error, reason}` on failure
  """
  @spec run(CodeMySpec.Users.Scope.t(), map()) :: {:ok, String.t(), map()} | {:error, term()}
  def run(_scope, %{session_type: "submit_story_issue"}) do
    {:error,
     "Start story issue work with start_task using requirement_name submitted, " <>
       "entity_type issue, and the issue ID. The graph route checks the assigned " <>
       "coding agent and creates the issue-bound task."}
  end

  def run(scope, args) do
    external_id = Map.get(args, :external_id)
    session_type = Map.get(args, :session_type)
    module_name = Map.get(args, :module_name)

    cond do
      session_type in @bootstrap_tasks ->
        run_bootstrap_task(scope, external_id, session_type)

      session_type in @project_tasks ->
        run_project_task(scope, external_id, session_type)

      session_type in @componentless_tasks ->
        run_componentless_task(scope, external_id, session_type)

      session_type in @topic_tasks ->
        run_topic_task(scope, external_id, session_type, module_name)

      true ->
        run_component_task(scope, external_id, session_type, module_name)
    end
  end

  # Task dispatch goes through `apply/3`: task modules' `command/2` argument
  # shapes differ (`%{component_id: _}` vs `%{project_id: _}`), the session
  # type picks the module, and the type checker cannot see that correlation.
  defp run_bootstrap_task(scope, external_id, session_type) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, agent_task_module} <- resolve_session_type(session_type, nil) do
      {:ok, prompt} = apply(agent_task_module, :command, [scope, %{}])
      {:ok, prompt, %{}}
    end
  end

  defp run_project_task(scope, external_id, session_type) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, _} <- validate_environment(scope),
         {:ok, _project} <- get_project(scope),
         {:ok, sync_result} <- sync_project(scope),
         {:ok, agent_task_module} <- resolve_session_type(session_type, nil),
         {:ok, session} <- find_or_create_session(scope, external_id, agent_task_module),
         {:ok, _session} <- init_session_state(scope, session, agent_task_module),
         {:ok, prompt} <-
           apply(agent_task_module, :command, [scope, %{project_id: scope.active_project_id}]) do
      {:ok, with_project_context(prompt, scope), sync_result}
    end
  end

  # Task modules that mutate the session before `command/2` (e.g.
  # StartImplementation enabling continuous mode) export `init_session/2`.
  defp init_session_state(scope, session, agent_task_module) do
    # Load first: `function_exported?` is false for a module not yet loaded.
    Code.ensure_loaded?(agent_task_module)

    if Code.ensure_loaded?(agent_task_module) and
         function_exported?(agent_task_module, :init_session, 2) do
      agent_task_module.init_session(scope, session)
    else
      {:ok, session}
    end
  end

  defp run_componentless_task(scope, external_id, session_type) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, _} <- validate_environment(scope),
         {:ok, _project} <- get_project(scope),
         {:ok, sync_result} <- sync_project(scope),
         {:ok, agent_task_module} <- resolve_session_type(session_type, nil),
         {:ok, _session} <- create_session(scope, external_id, agent_task_module, nil),
         {:ok, prompt} <-
           apply(agent_task_module, :command, [scope, %{project_id: scope.active_project_id}]) do
      {:ok, with_project_context(prompt, scope), sync_result}
    end
  end

  defp run_topic_task(scope, external_id, session_type, topic) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, _} <- validate_environment(scope),
         {:ok, _project} <- get_project(scope),
         {:ok, sync_result} <- sync_project(scope),
         {:ok, agent_task_module} <- resolve_session_type(session_type, nil),
         {:ok, session} <- create_topic_session(scope, external_id, agent_task_module, topic),
         {:ok, task_attrs} <- topic_task(scope, session, agent_task_module, topic),
         {:ok, prompt} <- apply(agent_task_module, :command, [scope, task_attrs]) do
      {:ok, with_project_context(prompt, scope), sync_result}
    end
  end

  defp topic_task(scope, session, AgentTasks.QaStory, topic) do
    with {number, ""} <- Integer.parse(to_string(topic)),
         story when not is_nil(story) <- Stories.get_story_by_number(scope, number) do
      existing =
        Enum.find(TaskOwner.tasks(session), fn task ->
          task.requirement_name == "qa_complete" and task.story_id == story.id and
            task.status in [:active, :prepared, :blocked]
        end)

      qa_topic_task(scope, session, story, existing)
    else
      nil -> {:error, "QaStory: no story numbered #{topic} in this project"}
      _ -> {:error, "QaStory requires a numeric story number, got: #{inspect(topic)}"}
    end
  end

  defp topic_task(scope, _session, _module, topic),
    do: {:ok, %{project_id: scope.active_project_id, requirement_name: topic}}

  defp qa_topic_task(scope, session, story, nil) do
    attrs = %{
      id: Ecto.UUID.generate(),
      session_type: AgentTasks.QaStory,
      requirement_name: "qa_complete",
      story_id: story.id,
      project_id: scope.active_project_id,
      status: :active,
      started_at: DateTime.utc_now()
    }

    with {:ok, owner} <- TaskOwner.add_task(scope, session, attrs) do
      task = TaskOwner.find_task(owner, attrs.id)

      case Qa.capture_story_review(scope, owner, task) do
        {:ok, _} ->
          {:ok, task}

        {:error, reason} ->
          {:ok, _} = TaskOwner.complete_task(scope, owner, task.id, :cancelled)
          {:error, reason}
      end
    end
  end

  defp qa_topic_task(_scope, _session, _story, %{status: :blocked}),
    do: {:error, :task_blocked}

  defp qa_topic_task(scope, session, story, %{status: :prepared} = task) do
    with {:ok, owner} <- TaskOwner.activate_task(scope, session, task.id) do
      qa_topic_task(scope, owner, story, TaskOwner.find_task(owner, task.id))
    end
  end

  defp qa_topic_task(scope, session, story, task) do
    case Qa.capture_story_review(scope, session, task) do
      {:ok, _} ->
        {:ok, task}

      {:error, :qa_review_superseded} ->
        with {:ok, owner} <- TaskOwner.complete_task(scope, session, task.id, :cancelled),
             do: qa_topic_task(scope, owner, story, nil)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_component_task(scope, external_id, session_type, module_name) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, _} <- validate_environment(scope),
         {:ok, _project} <- get_project(scope),
         {:ok, sync_result} <- sync_project(scope),
         {:ok, component} <- get_component(scope, module_name),
         {:ok, agent_task_module} <- resolve_session_type(session_type, component),
         {:ok, _session} <- create_session(scope, external_id, agent_task_module, component),
         {:ok, prompt} <-
           apply(agent_task_module, :command, [
             scope,
             %{component_id: component.id, project_id: scope.active_project_id}
           ]) do
      {:ok, with_project_context(prompt, scope), sync_result}
    end
  end

  defp with_project_context(prompt, scope) do
    context =
      [
        project_context_header(),
        decisions_context(scope),
        architecture_reference()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    context <> "\n\n" <> prompt
  end

  defp project_context_header do
    "Read `#{Paths.base_dir()}/` for project documentation structure."
  end

  defp decisions_context(scope) do
    case Environments.read_file(CodeMySpec.AgentTasks.environment(scope), Paths.decisions_index()) do
      {:ok, content} when byte_size(content) > 0 ->
        """
        ## Architecture Decision Records

        The following technology decisions have been made for this project. \
        Follow these decisions — do not introduce alternatives without explicit instruction.

        #{String.trim(content)}

        For full rationale on any decision, read the linked file in `#{Paths.decisions_dir()}/`.\
        """

      _ ->
        nil
    end
  end

  defp architecture_reference do
    "For the component tree call `show_namespace_hierarchy`; for one component and its dependencies, `get_component`."
  end

  # Validation

  defp validate_external_id(nil) do
    {:error, "External ID is required"}
  end

  defp validate_external_id(external_id) when is_binary(external_id), do: {:ok, external_id}

  defp validate_environment(scope) do
    case CodeMySpec.AgentTasks.environment(scope) do
      nil -> {:error, "No environment configured (no working directory)"}
      env -> {:ok, env}
    end
  end

  # Session type resolution

  defp resolve_session_type(nil, _component) do
    {:error, "Session type is required. Valid types: #{Enum.join(valid_types(), ", ")}"}
  end

  defp resolve_session_type(name, _component) do
    case Map.get(session_type_map(), name) do
      nil ->
        {:error, "Unknown session type: #{name}. Valid types: #{Enum.join(valid_types(), ", ")}"}

      module ->
        {:ok, module}
    end
  end

  # Component lookup

  defp get_component(_scope, nil) do
    {:error, "Module name is required for this task type"}
  end

  defp get_component(nil, _module_name) do
    {:error, "No project configured"}
  end

  defp get_component(scope, module_name) do
    case Components.get_component_by_module_name(scope, module_name) do
      nil ->
        {:error, "Component not found with module name: #{module_name}"}

      component ->
        {:ok, component}
    end
  end

  # Project lookup

  defp get_project(nil) do
    {:error, "No project configured"}
  end

  defp get_project(scope) do
    case scope.active_project do
      nil -> {:error, "No active project"}
      project -> {:ok, project}
    end
  end

  # Session creation

  defp find_or_create_session(scope, external_id, session_module) do
    Sessions.find_or_create_session(scope, external_id, %{type: session_module})
  end

  defp create_session(scope, external_id, session_module, component) do
    attrs = %{
      type: session_module,
      component_module_name: component && component.module_name,
      state: if(component, do: %{"component_id" => component.id}, else: %{})
    }

    Sessions.find_or_create_session(scope, external_id, attrs)
  end

  defp create_topic_session(scope, external_id, session_module, topic) do
    attrs = %{
      type: session_module,
      state: %{"topic" => topic}
    }

    Sessions.find_or_create_session(scope, external_id, attrs)
  end

  # Sync — incremental only.

  defp sync_project(scope) do
    env = CodeMySpec.AgentTasks.environment(scope)
    base_dir = env && env.cwd

    if base_dir do
      # `changed_paths` keeps the component sync incremental.
      with {:ok, file_result} <- FileSync.sync(scope, base_dir: base_dir),
           {:ok, comp_result} <-
             FileComponentSync.sync_from_files(scope,
               base_dir: base_dir,
               changed_paths: file_result.changed_paths,
               removed_module_names: file_result.removed_module_names
             ) do
        {:ok,
         %{components: comp_result.all_components, changed: comp_result.changed_component_ids}}
      else
        # A light harness reports a root but cannot be scanned from here; it
        # is the file watcher for its checkout and syncs by manifest, so there
        # is nothing to catch up.
        {:error, {:cannot_scan, _reason}} ->
          {:ok, %{components: [], changed: []}}

        {:error, reason} ->
          {:error, "Sync failed: #{inspect(reason)}"}
      end
    else
      {:ok, %{components: [], changed: []}}
    end
  end
end
