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
  alias CodeMySpec.Paths
  alias CodeMySpec.Problems
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation.Pipeline

  # Maps session type names to AgentTask modules
  # Note: "spec" is handled specially in resolve_session_type/2 to auto-detect context vs component
  @session_type_map %{
    "component_spec" => AgentTasks.ComponentSpec,
    "context_spec" => AgentTasks.ContextSpec,
    "context_component_specs" => AgentTasks.ContextComponentSpecs,
    "context_design_review" => AgentTasks.ContextDesignReview,
    "develop_context" => AgentTasks.DevelopContext,
    "develop_controller" => AgentTasks.DevelopController,
    "develop_live_view" => AgentTasks.DevelopLiveView,
    "implement_context" => AgentTasks.ContextImplementation,
    "component_code" => AgentTasks.ComponentCode,
    "component_test" => AgentTasks.ComponentTest,
    "project_setup" => AgentTasks.ProjectSetup,
    "architecture_design" => AgentTasks.ArchitectureDesign,
    "architecture_review" => AgentTasks.ArchitectureReview,
    "write_bdd_specs" => AgentTasks.WriteBddSpecs,
    "manage_implementation" => AgentTasks.ManageImplementation,
    "design_ui" => AgentTasks.DesignUi,
    "liveview_spec" => AgentTasks.LiveViewSpec,
    "develop_live_context" => AgentTasks.DevelopLiveContext,
    "live_context_spec" => AgentTasks.LiveContextSpec,
    "technical_strategy" => AgentTasks.TechnicalStrategy,
    "research_topic" => AgentTasks.ResearchTopic,
    "qa_app" => AgentTasks.QaApp,
    "qa_setup" => AgentTasks.QaSetup,
    "qa_story" => AgentTasks.QaStory,
    "start_implementation" => AgentTasks.StartImplementation
  }

  # Tasks that run without a project or config.yml
  @bootstrap_tasks ["project_setup"]

  # Tasks that run a project-wide validation step (e.g. batch spex) before session creation
  @project_tasks ["start_implementation"]

  # Tasks that don't require a component/module_name
  @componentless_tasks [
    "project_setup",
    "architecture_design",
    "architecture_review",
    "write_bdd_specs",
    "manage_implementation",
    "design_ui",
    "technical_strategy",
    "qa_app",
    "qa_setup"
  ]

  # Tasks that take a topic name (passed as module_name arg) instead of a component lookup
  @topic_tasks ["research_topic", "qa_story"]

  @valid_types ["spec" | Map.keys(@session_type_map)]

  def valid_types, do: @valid_types
  def componentless_tasks, do: @componentless_tasks

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
         {:ok, spex_problems} <- Pipeline.run_all_spex(scope),
         :ok <- persist_spex_problems(scope, spex_problems),
         {:ok, agent_task_module} <- resolve_session_type(session_type, nil),
         {:ok, session} <- find_or_create_session(scope, external_id, agent_task_module),
         session <- enrich_session(session, nil, scope),
         {:ok, prompt} <- agent_task_module.command(scope, session) do
      {:ok, with_project_context(prompt, scope), sync_result}
    end
  end

  defp persist_spex_problems(_scope, []), do: :ok

  defp persist_spex_problems(scope, problems) do
    spex_files = problems |> Enum.map(& &1.file_path) |> Enum.uniq()
    Problems.replace_problems_for_files(scope, spex_files, problems)
    :ok
  end

  defp run_componentless_task(scope, external_id, session_type) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, _} <- validate_environment(scope),
         {:ok, _project} <- get_project(scope),
         {:ok, sync_result} <- sync_project(scope),
         {:ok, agent_task_module} <- resolve_session_type(session_type, nil),
         {:ok, session} <- create_session(scope, external_id, agent_task_module, nil),
         session <- enrich_session(session, nil, scope),
         {:ok, prompt} <- agent_task_module.command(scope, session) do
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
         session <- enrich_session(session, nil, scope),
         {:ok, prompt} <- agent_task_module.command(scope, session) do
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
         {:ok, session} <- create_session(scope, external_id, agent_task_module, component),
         session <- enrich_session(session, component, scope),
         {:ok, prompt} <- agent_task_module.command(scope, session) do
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
    {:ok, sessions} = Sessions.list_sessions(scope)

    case Enum.find(sessions, &(&1.type == session_module && &1.status == :active && &1.external_conversation_id == external_id)) do
      %Session{} = existing -> {:ok, existing}
      nil -> create_session(scope, external_id, session_module, nil)
    end
  end

  defp create_session(scope, external_id, session_module, component) do
    attrs = %{
      type: session_module,
      external_conversation_id: external_id,
      component_module_name: component && component.module_name,
      state: if(component, do: %{"component_id" => component.id}, else: %{})
    }

    Sessions.create_session(scope, attrs)
  end

  defp create_topic_session(scope, external_id, session_module, topic) do
    attrs = %{
      type: session_module,
      external_conversation_id: external_id,
      component_module_name: nil,
      state: %{"topic" => topic}
    }

    Sessions.create_session(scope, attrs)
  end

  # Set virtual fields on the session struct
  defp enrich_session(%Session{} = session, component, scope) do
    %{session | component: component, project: scope.active_project}
  end

  # Sync

  defp sync_project(scope) do
    opts = if scope.environment, do: [base_dir: scope.environment.cwd], else: []

    case Sync.sync_all(scope, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, "Sync failed: #{inspect(reason)}"}
    end
  end
end
