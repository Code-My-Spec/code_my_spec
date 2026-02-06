defmodule CodeMySpec.AgentTasks.StartAgentTask do
  @moduledoc """
  Start an agent task session and generate the initial prompt.

  Creates a database Session with proper environment configuration,
  looks up the component if needed, and calls the appropriate AgentTask
  module to generate the prompt.

  ## Usage

  Called by CLI or other interfaces to start agent task sessions.
  Does not perform any IO - caller is responsible for output.

  ## Output

  Returns `{:ok, prompt}` on success or `{:error, reason}` on failure.
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Sessions
  alias CodeMySpec.AgentTasks

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
    "write_bdd_specs" => AgentTasks.WriteBddSpecs
  }

  # Tasks that don't require a component/module_name
  @componentless_tasks ["project_setup", "architecture_design", "architecture_review", "write_bdd_specs"]

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
  - `:working_dir` - Working directory (required)

  ## Returns

  - `{:ok, prompt, sync_result}` on success
  - `{:error, reason}` on failure
  """
  @spec run(CodeMySpec.Scope.t(), map()) :: {:ok, String.t(), map()} | {:error, term()}
  def run(scope, args) do
    external_id = Map.get(args, :external_id)
    session_type = Map.get(args, :session_type)
    module_name = Map.get(args, :module_name)
    working_dir = Map.get(args, :working_dir)

    if session_type in @componentless_tasks do
      run_componentless_task(scope, external_id, session_type, working_dir)
    else
      run_component_task(scope, external_id, session_type, module_name, working_dir)
    end
  end

  defp run_componentless_task(scope, external_id, session_type, working_dir) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, _} <- validate_working_dir(working_dir),
         {:ok, project} <- get_project(scope),
         {:ok, sync_result} <- sync_project(scope, working_dir),
         {:ok, agent_task_module} <- resolve_session_type(session_type, nil),
         {:ok, environment} <- build_environment(working_dir),
         {:ok, _db_session} <- create_componentless_session(scope, external_id, agent_task_module, environment),
         {:ok, task_session} <- build_componentless_task_session(external_id, project, environment),
         {:ok, prompt} <- agent_task_module.command(scope, task_session) do
      {:ok, prompt, sync_result}
    end
  end

  defp run_component_task(scope, external_id, session_type, module_name, working_dir) do
    with {:ok, _} <- validate_external_id(external_id),
         {:ok, _} <- validate_working_dir(working_dir),
         {:ok, project} <- get_project(scope),
         {:ok, sync_result} <- sync_project(scope, working_dir),
         {:ok, component} <- get_component(scope, module_name),
         {:ok, agent_task_module} <- resolve_session_type(session_type, component),
         {:ok, environment} <- build_environment(working_dir),
         {:ok, _db_session} <- create_session(scope, external_id, agent_task_module, component, environment),
         {:ok, task_session} <- build_task_session(external_id, component, project, environment),
         {:ok, prompt} <- agent_task_module.command(scope, task_session) do
      {:ok, prompt, sync_result}
    end
  end

  # Validation

  defp validate_external_id(nil) do
    {:error, "External ID is required"}
  end

  defp validate_external_id(external_id) when is_binary(external_id), do: {:ok, external_id}

  defp validate_working_dir(nil) do
    {:error, "Working directory is required"}
  end

  defp validate_working_dir(working_dir) when is_binary(working_dir), do: {:ok, working_dir}

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

  # Environment building - centralized here

  @doc """
  Build an Environment struct with the working directory properly configured.
  This is the single source of truth for environment creation in agent tasks.
  """
  def build_environment(working_dir) when is_binary(working_dir) do
    {:ok,
     %Environment{
       type: :cli,
       cwd: working_dir,
       ref: %{working_dir: working_dir},
       metadata: %{}
     }}
  end

  def build_environment(nil) do
    {:error, "Cannot build environment without working directory"}
  end

  # Session creation - stores environment as embedded schema

  defp create_session(scope, external_id, session_module, component, environment) do
    Sessions.create_session(scope, %{
      type: session_module,
      environment_type: :cli,
      agent: :claude_code,
      execution_mode: :manual,
      component_id: component.id,
      external_conversation_id: external_id,
      environment: environment_to_map(environment)
    })
  end

  defp create_componentless_session(scope, external_id, session_module, environment) do
    Sessions.create_session(scope, %{
      type: session_module,
      environment_type: :cli,
      agent: :claude_code,
      execution_mode: :manual,
      component_id: nil,
      external_conversation_id: external_id,
      environment: environment_to_map(environment)
    })
  end

  defp environment_to_map(%Environment{} = env) do
    %{
      type: env.type,
      cwd: env.cwd,
      ref: env.ref || %{},
      metadata: env.metadata || %{}
    }
  end

  # Task session building

  defp build_task_session(external_id, component, project, environment) do
    {:ok,
     %{
       external_id: external_id,
       component: component,
       project: project,
       environment_type: :cli,
       working_dir: environment.cwd,
       environment: environment
     }}
  end

  defp build_componentless_task_session(external_id, project, environment) do
    {:ok,
     %{
       external_id: external_id,
       project: project,
       environment_type: :cli,
       working_dir: environment.cwd,
       environment: environment
     }}
  end

  # Sync

  defp sync_project(scope, working_dir) do
    opts = [base_dir: working_dir]

    case Sync.sync_all(scope, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, "Sync failed: #{inspect(reason)}"}
    end
  end
end
