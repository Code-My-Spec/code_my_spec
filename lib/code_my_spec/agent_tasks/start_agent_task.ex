defmodule CodeMySpec.AgentTasks.StartAgentTask do
  @moduledoc """
  Start an agent task session and generate the initial prompt.

  Creates a filesystem-backed Session with proper configuration,
  looks up the component if needed, sets virtual fields on the session,
  and calls the appropriate AgentTask module to generate the prompt.

  ## Usage

  Called by CLI or other interfaces to start agent task sessions.
  Does not perform any IO - caller is responsible for output.

  ## Output

  Returns `{:ok, prompt}` on success or `{:error, reason}` on failure.
  """

  require Logger

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Paths
  alias CodeMySpec.ProjectSync.FileWatcherServer
  alias CodeMySpec.Sessions

  # Maps session type names to AgentTask modules
  # Note: "spec" is handled specially in resolve_session_type/2 to auto-detect context vs component
  @session_type_map %{
    "component_spec" => AgentTasks.ComponentSpec,
    "context_spec" => AgentTasks.ContextSpec,
    "context_design_review" => AgentTasks.ContextDesignReview,
    "develop_context" => AgentTasks.DevelopContext,
    "fix_all_bdd_specs" => AgentTasks.FixAllBddSpecs,
    "fix_bdd_specs" => AgentTasks.FixBddSpecs,
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
    "liveview_spec" => AgentTasks.LiveViewSpec,
    "live_context_spec" => AgentTasks.LiveContextSpec,
    "technical_strategy" => AgentTasks.TechnicalStrategy,
    "research_topic" => AgentTasks.ResearchTopic,
    "qa_app" => AgentTasks.QaApp,
    "qa_integration_plan" => AgentTasks.QaIntegrationPlan,
    "qa_journey_plan" => AgentTasks.QaJourney,
    "qa_journey_execute" => AgentTasks.QaJourney,
    "qa_journey_wallaby" => AgentTasks.QaJourney,
    "qa_setup" => AgentTasks.QaSetup,
    "qa_story" => AgentTasks.QaStory,
    "start_implementation" => AgentTasks.StartImplementation,
    "three_amigos" => AgentTasks.ThreeAmigos,
    "triage_issues" => AgentTasks.TriageIssues,
    "fix_issues" => AgentTasks.FixIssues,
    "spex_boundary_ready" => AgentTasks.SpexBoundaryReady,
    "persona_research" => AgentTasks.PersonaResearch,
    "controller_spec" => AgentTasks.ControllerSpec,
    "init" => AgentTasks.Init
  }

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
    "qa_journey_wallaby",
    "qa_setup",
    "triage_issues",
    "fix_issues",
    "spex_boundary_ready",
    "persona_research"
  ]

  # Tasks that take a topic name (passed as module_name arg) instead of a component lookup.
  # `three_amigos` uses the topic slot for the story_id so the skill can
  # bypass the requirement-graph dispatch and start a session against any
  # story directly.
  @topic_tasks ["research_topic", "qa_story", "three_amigos"]

  @valid_types ["spec" | Map.keys(@session_type_map)]

  def valid_types, do: @valid_types
  def componentless_tasks, do: @componentless_tasks
  def session_type_map, do: @session_type_map
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

  defp run_bootstrap_task(scope, external_id, session_type) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, agent_task_module} <- resolve_session_type(session_type, nil) do
      # Bootstrap tasks get a minimal scope — just environment/cwd, no project needed
      bootstrap_scope = ensure_environment(scope)
      {:ok, prompt} = agent_task_module.command(bootstrap_scope, %{})
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
         {:ok, prompt} <- agent_task_module.command(scope, %{project_id: scope.active_project_id}) do
      {:ok, with_project_context(prompt, scope), sync_result}
    end
  end

  # Optional per-task session-state initialization. Task modules that need
  # to mutate the session before `command/2` runs (e.g. StartImplementation
  # enabling continuous mode) export `init_session/2` and own the mutation
  # themselves. This dispatcher keeps the per-task logic in the task module
  # so MCP tools and CLI entry points share one source of truth.
  defp init_session_state(scope, session, agent_task_module) do
    # Ensure the module is loaded before `function_exported?` — otherwise
    # the very first call after boot returns false because the BEAM
    # hasn't pulled in the task module yet, and the session-state hook
    # silently skips (e.g., StartImplementation never sets continuous).
    Code.ensure_loaded?(agent_task_module)

    if function_exported?(agent_task_module, :init_session, 2) do
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
         {:ok, prompt} <- agent_task_module.command(scope, %{project_id: scope.active_project_id}) do
      {:ok, with_project_context(prompt, scope), sync_result}
    end
  end

  defp run_topic_task(scope, external_id, session_type, topic) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, _} <- validate_environment(scope),
         {:ok, _project} <- get_project(scope),
         {:ok, sync_result} <- sync_project(scope),
         {:ok, agent_task_module} <- resolve_session_type(session_type, nil),
         {:ok, _session} <- create_topic_session(scope, external_id, agent_task_module, topic),
         task_attrs <- %{project_id: scope.active_project_id, requirement_name: topic},
         {:ok, prompt} <- agent_task_module.command(scope, task_attrs) do
      {:ok, with_project_context(prompt, scope), sync_result}
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
           agent_task_module.command(scope, %{
             component_id: component.id,
             project_id: scope.active_project_id
           }) do
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
    case Environments.read_file(scope.environment, Paths.decisions_index()) do
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
    "For system component graph and dependencies, read `#{Paths.architecture_dir()}/overview.md`."
  end

  # Validation

  defp validate_external_id(nil) do
    {:error, "External ID is required"}
  end

  defp validate_external_id(external_id) when is_binary(external_id), do: {:ok, external_id}

  # Ensures scope has an environment, building a minimal one from cwd if needed
  defp ensure_environment(%{environment: nil, cwd: cwd} = scope) when is_binary(cwd) do
    %{scope | environment: Environment.new(:local, cwd)}
  end

  defp ensure_environment(%{environment: nil} = scope) do
    cwd = File.cwd!()
    %{scope | environment: Environment.new(:local, cwd)}
  end

  defp ensure_environment(scope), do: scope

  defp validate_environment(%{environment: nil}) do
    {:error, "No environment configured (no working directory)"}
  end

  defp validate_environment(%{environment: env}) when not is_nil(env), do: {:ok, env}

  # Session type resolution

  defp resolve_session_type(nil, _component) do
    {:error, "Session type is required. Valid types: #{Enum.join(@valid_types, ", ")}"}
  end

  # Auto-detect context vs component vs liveview spec based on component type
  defp resolve_session_type("spec", %{type: "live_context"}) do
    {:ok, AgentTasks.LiveContextSpec}
  end

  defp resolve_session_type("spec", %{type: type})
       when type in ["liveview", "liveview_component"] do
    {:ok, AgentTasks.LiveViewSpec}
  end

  defp resolve_session_type("spec", component) do
    if Components.context?(component) do
      {:ok, AgentTasks.ContextSpec}
    else
      {:ok, AgentTasks.ComponentSpec}
    end
  end

  defp resolve_session_type(name, _component) do
    case Map.get(@session_type_map, name) do
      nil ->
        {:error, "Unknown session type: #{name}. Valid types: #{Enum.join(@valid_types, ", ")}"}

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

  # Sync — incremental only. File watcher handles continuous sync;
  # this catches anything it missed (e.g., files changed while Claude wasn't running).

  defp sync_project(scope) do
    base_dir = scope.environment && scope.environment.cwd
    FileWatcherServer.ensure_watching(scope)

    if base_dir do
      # `embed: false` — `start_task` is on the request hot path. The
      # framework-knowledge re-embed + hex doc re-projection belong to
      # boot / mix.lock-poll / explicit `sync_project`, not every task
      # start.
      with {:ok, _file_result} <- FileSync.sync(scope, base_dir: base_dir, embed: false),
           {:ok, comp_result} <- FileComponentSync.sync_from_files(scope, base_dir: base_dir) do
        {:ok,
         %{components: comp_result.all_components, changed: comp_result.changed_component_ids}}
      else
        {:error, reason} -> {:error, "Sync failed: #{inspect(reason)}"}
      end
    else
      {:ok, %{components: [], changed: []}}
    end
  end
end
