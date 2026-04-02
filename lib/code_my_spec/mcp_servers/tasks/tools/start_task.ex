defmodule CodeMySpec.McpServers.Tasks.Tools.StartTask do
  @moduledoc """
  Start working on a requirement.

  Takes a requirement_id (from `list_requirements` or `get_next_requirement`),
  creates and activates a task on your session in one step, and returns the
  work prompt.

  The `session_id` is injected automatically by the PreToolUse hook — you
  don't need to pass it. Optionally pass `agent_id` to claim ownership
  (useful when a subagent starts the task).

  If a task already exists for this requirement on your session, it returns
  the prompt without creating a duplicate.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.McpServers.Tasks.TasksMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :requirement_name, :string,
      required: true,
      doc: "Name of the requirement (e.g., spec_file, implementation_file)"

    field :entity_type, :string,
      required: true,
      doc: "Entity type: component, story, or project"

    field :entity_id, :string,
      required: true,
      doc: "ID of the entity that owns this requirement"

    field :session_id, :string,
      doc: "Injected by hook — do not set manually"

    field :agent_id, :string,
      doc: "Your agent identifier — claims ownership of the task"

    # Legacy — kept for backwards compatibility
    field :requirement_id, :string,
      doc: "Deprecated: use requirement_name + entity_type + entity_id"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)
    agent_id = Map.get(params, :agent_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, requirement} <- resolve_requirement(scope, params),
         {:ok, session} <- resolve_session(scope, session_id) do
      start_or_resume(scope, session, requirement, agent_id, frame)
    else
      {:error, reason} ->
        {:reply, TasksMapper.error(reason), frame}
    end
  end

  defp resolve_requirement(scope, %{requirement_name: name, entity_type: type, entity_id: id})
       when is_binary(name) and is_binary(type) and is_binary(id) do
    resolve_from_graph(scope, name, type, id)
  end

  defp resolve_requirement(_scope, _params) do
    {:error, "Must provide requirement_name + entity_type + entity_id"}
  end

  defp resolve_from_graph(scope, name, entity_type, entity_id) do
    # Find the matching node in the computed graph
    all_nodes = RequirementGraph.compute_all(scope)

    case Enum.find(all_nodes, fn n ->
           n.name == name and n.entity_type == entity_type and to_string(n.entity_id) == entity_id
         end) do
      nil ->
        {:error, "Requirement #{name} not found for #{entity_type} #{entity_id}"}

      node ->
        {:ok, node}
    end
  end

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    case Sessions.get_by_external_id(scope, session_id) do
      nil ->
        # Try as DB UUID
        case safe_get_session(scope, session_id) do
          nil -> {:error, "Session not found: #{session_id}. Has the SessionStart hook fired?"}
          session -> {:ok, session}
        end

      session ->
        {:ok, session}
    end
  end

  defp resolve_session(_scope, _session_id) do
    {:error, "No session_id available. The PreToolUse hook should inject it automatically."}
  end

  defp safe_get_session(scope, id) do
    Sessions.get_session(scope, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp start_or_resume(scope, session, requirement, agent_id, frame) do
    # Check for existing task for this requirement
    existing =
      (session.tasks || [])
      |> Enum.find(fn t ->
        t.requirement_name == requirement.name and t.status in [:prepared, :active]
      end)

    case existing do
      %{status: :active} = task ->
        # Already active — just return the prompt
        if agent_id && is_nil(task.agent_id) do
          Sessions.assign_agent(scope, session, task.id, agent_id)
        end

        prompt = generate_prompt(task, scope)
        {:reply, TasksMapper.prompt_response(prompt, task), frame}

      %{status: :prepared} = task ->
        # Prepared but not started — activate it
        case Sessions.activate_task(scope, session, task.id, agent_id) do
          {:ok, _updated} ->
            prompt = generate_prompt(task, scope)
            {:reply, TasksMapper.prompt_response(prompt, task), frame}

          {:error, reason} ->
            {:reply, TasksMapper.error("Failed to activate task: #{inspect(reason)}"), frame}
        end

      nil ->
        # No existing task — create and activate in one step
        create_and_activate(scope, session, requirement, agent_id, frame)
    end
  end

  defp create_and_activate(scope, session, requirement, agent_id, frame) do
    {component_id, component_module_name, story_id} =
      case requirement.entity_type do
        "component" ->
          comp = Components.get_component(scope, requirement.entity_id)
          {requirement.entity_id, comp && comp.module_name, nil}

        "story" ->
          {nil, nil, requirement.entity_id}

        _ ->
          {nil, nil, nil}
      end

    task_attrs = %{
      id: Ecto.UUID.generate(),
      session_type: requirement.satisfied_by,
      requirement_name: requirement.name,
      project_id: scope.active_project_id,
      component_id: component_id,
      component_module_name: component_module_name,
      story_id: story_id,
      execution_type: requirement.execution_type || :main_agent,
      validation_type: requirement.validation_type || :automatic,
      status: :active,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      agent_id: agent_id
    }

    # Enable continuous mode if starting implementation
    session =
      if requirement.satisfied_by == CodeMySpec.AgentTasks.StartImplementation do
        state = Map.put(session.state || %{}, "continuous", true)
        {:ok, s} = Sessions.update_session(scope, session, %{state: state})
        s
      else
        session
      end

    case session |> Session.add_task(task_attrs) |> Repo.update() do
      {:ok, updated_session} ->
        task = Session.find_task(updated_session, task_attrs.id)
        prompt = generate_prompt(task, scope)
        {:reply, TasksMapper.prompt_response(prompt, task), frame}

      {:error, reason} ->
        Logger.warning("[StartTask] Failed to create task: #{inspect(reason)}")
        {:reply, TasksMapper.error("Failed to create task: #{inspect(reason)}"), frame}
    end
  end

  defp generate_prompt(task, scope) do
    task_module = task.session_type

    if is_nil(task_module) do
      "No task module configured for this task."
    else
      prompt =
        case task_module.command(scope, task) do
          {:ok, text} -> text
          {:error, reason} -> "Error generating prompt: #{inspect(reason)}"
        end

      prompt
    end
  rescue
    error -> "Error: #{inspect(error)}"
  end

end
