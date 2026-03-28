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

  alias CodeMySpec.McpServers.Tasks.TasksMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :requirement_id, :string,
      required: true,
      doc: "ID of the requirement to work on (from list_requirements or get_next_requirement)"

    field :session_id, :string,
      doc: "Injected by hook — do not set manually"

    field :agent_id, :string,
      doc: "Your agent identifier — claims ownership of the task"
  end

  @impl true
  def execute(%{requirement_id: requirement_id} = params, frame) do
    session_id = Map.get(params, :session_id)
    agent_id = Map.get(params, :agent_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, requirement} <- get_requirement(requirement_id),
         {:ok, session} <- resolve_session(scope, session_id) do
      start_or_resume(scope, session, requirement, agent_id, frame)
    else
      {:error, reason} ->
        {:reply, TasksMapper.error(reason), frame}
    end
  end

  defp get_requirement(requirement_id) do
    case Requirements.get_requirement(requirement_id) do
      nil -> {:error, "Requirement not found: #{requirement_id}"}
      req -> {:ok, Repo.preload(req, [:component, :story, :project])}
    end
  rescue
    Ecto.Query.CastError -> {:error, "Requirement not found: #{requirement_id}"}
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
    task_attrs = %{
      id: Ecto.UUID.generate(),
      session_type: requirement.satisfied_by,
      requirement_id: requirement.id,
      requirement_name: requirement.name,
      project_id: scope.active_project_id,
      component_id: requirement.component_id,
      component_module_name:
        case requirement.component do
          %{module_name: name} -> name
          _ -> nil
        end,
      story_id: requirement.story_id,
      execution_type: requirement.execution_type || :main_agent,
      validation_type: requirement.validation_type || :automatic,
      status: :active,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      agent_id: agent_id
    }

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

      prompt <> checklist_section(task)
    end
  rescue
    error -> "Error: #{inspect(error)}"
  end

  defp checklist_section(%{requirement_id: nil}), do: ""

  defp checklist_section(%{requirement_id: req_id}) do
    case Requirements.get_requirement(req_id) do
      nil -> ""
      requirement -> render_checklist(requirement)
    end
  end

  defp render_checklist(requirement) do
    checklist = get_in(requirement.details, ["checklist"]) || []

    if checklist == [] do
      ""
    else
      done = Enum.count(checklist, fn item -> item["satisfied"] || false end)
      total = length(checklist)

      lines =
        Enum.map_join(checklist, "\n", fn item ->
          check = if item["satisfied"] || false, do: "[x]", else: "[ ]"

          detail =
            if item["detail"] && !(item["satisfied"] || false), do: " — #{item["detail"]}", else: ""

          "- #{check} #{item["name"]}#{detail}"
        end)

      "\n\n## Steps (#{done}/#{total})\n\n#{lines}\n"
    end
  end
end
