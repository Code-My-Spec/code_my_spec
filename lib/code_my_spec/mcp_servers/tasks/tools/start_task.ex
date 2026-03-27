defmodule CodeMySpec.McpServers.Tasks.Tools.StartTask do
  @moduledoc """
  Activate a prepared task and receive the prompt.

  Call this after `draft_task` to transition the task from prepared to active
  and get the actual work prompt. The calling agent should pass its agent_id
  to claim ownership of the task.

  For `:main_agent` tasks, the orchestrating agent calls this directly.
  For `:sub_agent` tasks, the orchestrating agent passes session_id and task_id
  to a subagent, and the subagent calls this to claim and start the work.

  If the task is already active (e.g. you're resuming), it returns the prompt
  again without error.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Tasks.TasksMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :session_id, :string,
      required: true,
      doc: "Session ID returned by draft_task"

    field :task_id, :string,
      required: true,
      doc: "Task ID returned by draft_task"

    field :agent_id, :string,
      doc: "Your agent identifier — claims ownership of the task"
  end

  @impl true
  def execute(%{session_id: session_id, task_id: task_id} = params, frame) do
    agent_id = Map.get(params, :agent_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- get_session(scope, session_id),
         {:ok, task} <- find_task(session, task_id) do
      handle_task(scope, session, task, agent_id, frame)
    else
      {:error, :session_not_found} ->
        {:reply, TasksMapper.session_not_found(session_id), frame}

      {:error, :task_not_found} ->
        {:reply, TasksMapper.task_not_found(task_id), frame}

      {:error, reason} ->
        {:reply, TasksMapper.error(reason), frame}
    end
  end

  defp get_session(scope, session_id) do
    session =
      try do
        Sessions.get_session(scope, session_id)
      rescue
        Ecto.Query.CastError -> nil
      end

    case session do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
  end

  defp find_task(session, task_id) do
    case Session.find_task(session, task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, task}
    end
  end

  defp handle_task(scope, session, %{status: :active} = task, agent_id, frame) do
    if agent_id && is_nil(task.agent_id) do
      Sessions.assign_agent(scope, session, task.id, agent_id)
    end

    prompt = generate_prompt(task, scope)
    {:reply, TasksMapper.prompt_response(prompt, task), frame}
  end

  defp handle_task(scope, session, %{status: :prepared} = task, agent_id, frame) do
    case Sessions.activate_task(scope, session, task.id, agent_id) do
      {:ok, _updated} ->
        prompt = generate_prompt(task, scope)
        {:reply, TasksMapper.prompt_response(prompt, task), frame}

      {:error, reason} ->
        {:reply, TasksMapper.error("Failed to activate task: #{inspect(reason)}"), frame}
    end
  end

  defp handle_task(_scope, _session, %{status: status}, _agent_id, frame) do
    {:reply, TasksMapper.task_not_startable(status), frame}
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
          detail = if item["detail"] && !(item["satisfied"] || false), do: " — #{item["detail"]}", else: ""
          "- #{check} #{item["name"]}#{detail}"
        end)

      "\n\n## Steps (#{done}/#{total})\n\n#{lines}\n"
    end
  end
end
