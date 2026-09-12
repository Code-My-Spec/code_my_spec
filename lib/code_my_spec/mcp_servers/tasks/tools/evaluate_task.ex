defmodule CodeMySpec.McpServers.Tasks.Tools.EvaluateTask do
  @moduledoc """
  Evaluate a task's work and get pass/fail feedback.

  Call this when you've completed the work for a task with manual validation.
  The task's module evaluates your work against its criteria.

  On pass: the task is marked completed and the requirement is rechecked.
  On fail: you receive feedback describing what needs fixing.

  Tasks with automatic validation are evaluated by the stop hook — you don't
  need to call this for those.

  The `session_id` is injected automatically by the PreToolUse hook.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.AgentTasks.Evaluator
  alias CodeMySpec.McpServers.Tasks.TasksMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Utils

  schema do
    field :task_id, :string,
      required: true,
      doc: "Task ID to evaluate"

    field :session_id, :string, doc: "Injected by hook — do not set manually"
  end

  @impl true
  def execute(%{task_id: task_id} = params, frame) do
    # Who is calling, off the connection — see `start_task` and
    # `Plugs.AgentScope`. An agent we run has no session to name and no way to
    # get one, so without this it could start a task and never close it, which
    # is the half of the loop that tells the other roles work is done.
    caller_agent_id = frame.assigns[:agent_id]
    session_id = Map.get(params, :session_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, owner} <- resolve_owner(scope, session_id, caller_agent_id),
         {:ok, task} <- find_task(owner, task_id) do
      handle_evaluate(scope, owner, task, frame)
    else
      {:error, :session_not_found} ->
        {:reply, TasksMapper.session_not_found(session_id || "unknown"), frame}

      {:error, :task_not_found} ->
        {:reply, TasksMapper.task_not_found(task_id), frame}

      {:error, reason} ->
        {:reply, TasksMapper.error(reason), frame}
    end
  end

  # An agent we run owns its tasks directly, so it is the owner and there is no
  # session in the picture. Ahead of the session clause for the same reason as
  # in `start_task`: a call carrying both is one of ours, and the agent is what
  # holds the task it is closing.
  defp resolve_owner(scope, _session_id, agent_id) when is_binary(agent_id) do
    Agents.fetch_agent(scope, agent_id)
  end

  defp resolve_owner(scope, session_id, _agent_id), do: resolve_session(scope, session_id)

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    session =
      Sessions.get_by_external_id(scope, session_id) ||
        Utils.safe_get(fn -> Sessions.get_session(scope, session_id) end)

    case session do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
  end

  defp resolve_session(_scope, _session_id) do
    {:error, no_owner_message()}
  end

  defp find_task(owner, task_id) do
    case TaskOwner.find_task(owner, task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, task}
    end
  end

  defp handle_evaluate(_scope, _owner, %{status: status}, frame)
       when status in [:completed, :failed, :cancelled] do
    {:reply, TasksMapper.task_already_terminal(status), frame}
  end

  defp handle_evaluate(scope, owner, task, frame) do
    task_module = task.session_type

    if is_nil(task_module) do
      {:reply, TasksMapper.error("No task module configured for this task"), frame}
    else
      result = dispatch_evaluate(task_module, scope, task)

      case result do
        {:ok, :valid} ->
          {:ok, _} = TaskOwner.complete_task(scope, owner, task.id, :completed)
          clear_feedback(scope, owner)

          Logger.info(
            "[EvaluateTask] #{type_name(task_module)} passed — task #{task.id} completed"
          )

          {:reply, TasksMapper.evaluate_passed_response(task), frame}

        {:ok, :valid, info} ->
          {:ok, _} = TaskOwner.complete_task(scope, owner, task.id, :completed)
          clear_feedback(scope, owner)

          Logger.info(
            "[EvaluateTask] #{type_name(task_module)} passed with info — task #{task.id} completed"
          )

          {:reply, TasksMapper.evaluate_passed_response(task, info), frame}

        {:ok, :invalid, feedback} ->
          # R8: hash the feedback and bump (or reset) the session-level
          # repeat counter so the stop hook can detect a stuck loop —
          # this surface (manual evaluate) and TaskEvaluator (auto stop
          # hook) share the same session-scoped counter.
          record_feedback(scope, owner, feedback)
          Logger.info("[EvaluateTask] #{type_name(task_module)} failed — feedback returned")
          {:reply, TasksMapper.evaluate_needs_work_response(task, feedback), frame}

        {:error, reason} ->
          Logger.warning("[EvaluateTask] #{type_name(task_module)} error: #{inspect(reason)}")
          {:reply, TasksMapper.evaluate_error_response(task, reason), frame}
      end
    end
  end

  # Modules with custom evaluate logic bypass the unified Evaluator.
  # Everything else goes through the Evaluator (FileSync + RequirementCalculator).
  defp dispatch_evaluate(module, scope, task) do
    if Evaluator.has_custom_evaluate?(module) do
      module.evaluate(scope, task)
    else
      Evaluator.evaluate(scope, task)
    end
  rescue
    e -> {:error, "Evaluation failed: #{Exception.message(e)}"}
  end

  # R8's repeat counter lives on the session, and an agent we run has its own —
  # `StopDecision` keys it on the agent, because "the session was never the
  # right identity for who was told". So these are session-shaped by design
  # rather than by omission, and an agent owner is a no-op here.
  defp record_feedback(scope, %Session{} = session, feedback),
    do: Sessions.record_eval_feedback(scope, session, feedback)

  defp record_feedback(_scope, _owner, _feedback), do: :ok

  defp clear_feedback(scope, %Session{} = session),
    do: Sessions.clear_eval_feedback(scope, session)

  defp clear_feedback(_scope, _owner), do: :ok

  defp type_name(module) do
    module |> Atom.to_string() |> String.split(".") |> List.last()
  end

  # Neither identity arrived, so there is nothing to look the task up on.
  #
  # `register_session` is named only where it can be followed. It is a Claude
  # Code tool and no coding agent carries one — an Alloy agent told to call it
  # gets "register_session is not a tool a coding agent carries" and is no
  # closer, which is exactly what happened on 2026-09-06 while its task stayed
  # open.
  defp no_owner_message do
    "No session_id and no agent id on this call, so there is no owner to find " <>
      "the task on.\n\n" <>
      "If you are Claude Code: `register_session` with this conversation's id " <>
      "(CLAUDE_SESSION_ID) creates it on this server.\n\n" <>
      "If you are an agent we run: your id travels on the connection and you " <>
      "cannot supply it — this is a harness fault, not something to retry or " <>
      "spell differently. Report it with `create_issue` and carry on with work " <>
      "that does not need the task closed."
  end
end
