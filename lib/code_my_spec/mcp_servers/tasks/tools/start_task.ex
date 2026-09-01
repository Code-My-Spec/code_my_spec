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

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Tasks.TasksMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :requirement_name, :string,
      required: true,
      doc: "Name of the requirement (e.g., spec_file, implementation_file)"

    field :entity_type, :string,
      required: true,
      doc: "Entity type: component, story, or project"

    field :entity_id, :string, doc: "ID of the entity that owns this requirement"

    field :module_name, :string,
      doc: "Component module name (alternative to entity_id for component requirements)"

    field :session_id, :string, doc: "Injected by hook — do not set manually"

    field :agent_id, :string, doc: "Your agent identifier — claims ownership of the task"

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

  defp resolve_requirement(scope, %{requirement_name: name, module_name: module_name})
       when is_binary(name) and is_binary(module_name) do
    case Components.get_component_by_module_name(scope, module_name) do
      nil -> {:error, "Component not found: #{module_name}"}
      component -> resolve_from_graph(scope, name, "component", component.id)
    end
  end

  defp resolve_requirement(_scope, _params) do
    {:error,
     "Must provide requirement_name + entity_type + entity_id, or requirement_name + module_name"}
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
        # Try as DB UUID (an agent may pass the internal id), then lazily
        # register. On the first session of a conversation the SessionStart
        # hook may not have fired — Claude Code loads hooks once at session
        # start, so a session opened before the plugin's hooks were enabled
        # never gets its session row, and the agent would dead-end here until
        # a full /clear + restart. Rather than error, create the row under the
        # same scope the hook would have used (the /mcp pipeline and the hook
        # pipeline both resolve it from the harness id), so the flow self-heals
        # in place.
        case safe_get_session(scope, session_id) do
          nil -> lazily_register_session(scope, session_id)
          session -> {:ok, session}
        end

      session ->
        {:ok, session}
    end
  end

  defp resolve_session(_scope, _session_id) do
    {:error,
     "No session_id available. Call `register_session` with this conversation's id (CLAUDE_SESSION_ID) to create it on this server."}
  end

  defp lazily_register_session(scope, session_id) do
    case Sessions.find_or_create_session(scope, session_id) do
      {:ok, session} ->
        {:ok, session}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "Could not register session #{session_id}: #{inspect(changeset.errors)}"}
    end
  end

  defp safe_get_session(scope, id) do
    Sessions.get_session(scope, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp start_or_resume(scope, session, requirement, agent_id, frame) do
    # Check for existing task for this exact requirement + entity. Must
    # match on entity ID too — multiple subagents may have tasks with the
    # same requirement_name for different components.
    entity_id = to_string(requirement.entity_id)
    existing = find_existing_task(session, requirement, entity_id)
    handle_existing(existing, scope, session, requirement, agent_id, frame)
  end

  defp find_existing_task(session, requirement, entity_id) do
    Enum.find(session.tasks || [], fn t ->
      t.requirement_name == requirement.name and
        t.status in [:prepared, :active] and
        matches_entity?(t, requirement.entity_type, entity_id)
    end)
  end

  defp handle_existing(nil, scope, session, requirement, agent_id, frame),
    do: create_and_activate(scope, session, requirement, agent_id, frame)

  defp handle_existing(%{status: :active} = task, scope, session, _req, agent_id, frame) do
    maybe_assign_agent(scope, session, task, agent_id)
    return_prompt(task, scope, frame)
  end

  defp handle_existing(%{status: :prepared} = task, scope, session, _req, agent_id, frame) do
    case Sessions.activate_task(scope, session, task.id, agent_id) do
      {:ok, _updated} ->
        # Activation is the hand-over, whichever way the task got here. A
        # session prepares its whole chain up front, so most work an agent is
        # given was a row before it was given — noting only creation would miss
        # every ordinary case and catch only the first.
        note_handover(scope, agent_id, task)
        return_prompt(task, scope, frame)

      {:error, reason} ->
        {:reply, TasksMapper.error("Failed to activate task: #{inspect(reason)}"), frame}
    end
  end

  defp return_prompt(task, scope, frame) do
    prompt = generate_prompt(task, scope)
    {:reply, TasksMapper.prompt_response(prompt, task), frame}
  end

  defp maybe_assign_agent(scope, session, %{agent_id: nil, id: task_id}, agent_id)
       when is_binary(agent_id) do
    Sessions.assign_agent(scope, session, task_id, agent_id)
  end

  defp maybe_assign_agent(_scope, _session, _task, _agent_id), do: :ok

  defp create_and_activate(scope, session, requirement, agent_id, frame) do
    task_attrs = build_task_attrs(scope, requirement, agent_id)
    session = maybe_init_session(scope, session, requirement.satisfied_by)

    case session |> Session.add_task(task_attrs) |> Repo.update() do
      {:ok, updated_session} ->
        task = Session.find_task(updated_session, task_attrs.id)
        note_handover(scope, agent_id, requirement)
        return_prompt(task, scope, frame)

      {:error, reason} ->
        Logger.warning("[StartTask] Failed to create task: #{inspect(reason)}")
        {:reply, TasksMapper.error("Failed to create task: #{inspect(reason)}"), frame}
    end
  end

  # The agent being given work, on its own thread. Story 985: an agent that
  # suddenly starts on something new had no visible cause, because the thing
  # that gave it the work is the orchestrator rather than anything the agent
  # said.
  #
  # No count: handing over a requirement has no quantity, and a blank number
  # renders as one that means nothing.
  defp note_handover(scope, agent_id, work) do
    Conversations.record_orchestrator_action(
      agent_id || Agents.main_agent(scope),
      "Gave you the next requirement: #{handover_name(work)}.",
      kind: "handover"
    )
  rescue
    error ->
      Logger.warning("[StartTask] could not record the hand-over: " <> Exception.message(error))
      :ok
  end

  # A requirement names itself; a task names the requirement it satisfies.
  defp handover_name(%{name: name}) when is_binary(name), do: name
  defp handover_name(%{requirement_name: name}) when is_binary(name), do: name
  defp handover_name(_work), do: "work"

  defp build_task_attrs(scope, requirement, agent_id) do
    {component_id, component_module_name, story_id} = build_entity_refs(scope, requirement)

    %{
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
      # Microsecond resolution so started_at lands strictly past any
      # file mtime synced earlier in the same request. Lets
      # Validation.changed_since short-circuit deterministically
      # without sleeping across a second boundary in tests.
      started_at: DateTime.utc_now(),
      agent_id: agent_id
    }
  end

  defp build_entity_refs(scope, %{entity_type: "component", entity_id: id}) do
    comp = Components.get_component(scope, id)
    {id, comp && comp.module_name, nil}
  end

  defp build_entity_refs(_scope, %{entity_type: "story", entity_id: id}), do: {nil, nil, id}
  defp build_entity_refs(_scope, _req), do: {nil, nil, nil}

  defp maybe_init_session(scope, session, task_module) do
    if function_exported?(task_module, :init_session, 2) do
      {:ok, s} = task_module.init_session(scope, session)
      s
    else
      session
    end
  end

  defp matches_entity?(task, "component", entity_id) do
    to_string(task.component_id) == entity_id
  end

  defp matches_entity?(task, "story", entity_id) do
    to_string(task.story_id) == entity_id
  end

  defp matches_entity?(task, "project", entity_id) do
    to_string(task.project_id) == entity_id
  end

  defp matches_entity?(_task, _type, _id), do: true

  defp generate_prompt(task, scope) do
    task_module = task.session_type

    if is_nil(task_module) do
      "No task module configured for this task."
    else
      prompt =
        case task_module.command(scope, task) do
          {:ok, text} -> text
          {:error, reason} -> "Error generating prompt: #{format_error_reason(reason)}"
        end

      prompt
    end
  rescue
    error -> "Error: #{inspect(error)}"
  end

  # Task modules may return `{:error, atom}` (terse code) or
  # `{:error, {atom, message}}` (terse code + agent-actionable
  # message). Prefer the message when present.
  defp format_error_reason(reason), do: CodeMySpec.AgentTasks.format_error(reason)
end
