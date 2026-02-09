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
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  # Maps session type names to AgentTask modules
  # Note: "spec" is handled specially in resolve_session_type/2 to auto-detect context vs component
  @session_type_map %{
    "component_spec" => AgentTasks.ComponentSpec,
    "context_spec" => AgentTasks.ContextSpec,
    "context_component_specs" => AgentTasks.ContextComponentSpecs,
    "context_design_review" => AgentTasks.ContextDesignReview,
    "develop_context" => AgentTasks.DevelopContext,
    "implement_context" => AgentTasks.ContextImplementation,
    "component_code" => AgentTasks.ComponentCode,
    "component_test" => AgentTasks.ComponentTest,
    "project_setup" => AgentTasks.ProjectSetup,
    "architecture_design" => AgentTasks.ArchitectureDesign,
    "architecture_review" => AgentTasks.ArchitectureReview,
    "write_bdd_specs" => AgentTasks.WriteBddSpecs,
    "manage_implementation" => AgentTasks.ManageImplementation,
    "design_ui" => AgentTasks.DesignUi
  }

  # Tasks that don't require a component/module_name
  @componentless_tasks ["project_setup", "architecture_design", "architecture_review", "write_bdd_specs", "manage_implementation", "design_ui"]

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

    if session_type in @componentless_tasks do
      run_componentless_task(scope, external_id, session_type)
    else
      run_component_task(scope, external_id, session_type, module_name)
    end
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
      {:ok, prompt, sync_result}
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
      {:ok, prompt, sync_result}
    end
  end

  # Validation

  defp validate_external_id(nil) do
    {:error, "External ID is required"}
  end

  defp validate_external_id(external_id) when is_binary(external_id), do: {:ok, external_id}

  defp validate_environment(%{environment: nil}) do
    {:error, "No environment configured (no working directory)"}
  end

  defp validate_environment(%{environment: env}) when not is_nil(env), do: {:ok, env}

  # Session type resolution

  defp resolve_session_type(nil, _component) do
    {:error, "Session type is required. Valid types: #{Enum.join(@valid_types, ", ")}"}
  end

  # Auto-detect context vs component spec based on module structure
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

  defp create_session(scope, external_id, session_module, component) do
    attrs = %{
      type: session_module,
      external_conversation_id: external_id,
      component_module_name: component && component.module_name,
      state: if(component, do: %{"component_id" => component.id}, else: %{})
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
