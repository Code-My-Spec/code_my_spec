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
    field(:task_id, :string,
      required: true,
      description: "Task ID to evaluate"
    )

    field(:handoff_id, :string,
      description:
        "Report assigned artifact completion instead of evaluating; does not close the task or launch validation."
    )

    field(:artifact_sha, :string)
    field(:parent_commit, :string)
    field(:parent_gitlink, :string)

    field(:verification, :string,
      description: "Observed artifact and parent-gitlink verification; never a QA verdict."
    )

    field(:session_id, :string, description: "Injected by hook — do not set manually")

    field(:agent_id, :string,
      description: "Whose task to close. An agent we run carries it on the connection and omits this."
    )
  end

  @impl true
  def execute(%{task_id: task_id} = params, frame) do
    # Who is calling, off the connection — see `start_task` and
    # `Plugs.AgentScope`. An agent we run has no session to name and no way to
    # get one, so without this it could start a task and never close it, which
    # is the half of the loop that tells the other roles work is done.
    # The connection first, then the argument.
    #
    # `start_task` takes an `agent_id` and this did not, so a task could be
    # opened on an agent's behalf and never closed on it — the orchestrator
    # that hands work out could not take it back, and an agent holding an
    # active task is not runnable, so the agent was stranded rather than
    # merely blocked.
    #
    # The connection wins where it has one: an agent we run cannot spoof
    # another by naming it, because `Plugs.AgentScope` has already said who it
    # is and the argument is never consulted.
    caller_agent_id = frame.assigns[:agent_id] || Map.get(params, :agent_id)
    session_id = Map.get(params, :session_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, owner} <- resolve_owner(scope, session_id, caller_agent_id),
         {:ok, task} <- find_task(owner, task_id) do
      case Map.get(params, :handoff_id) do
        nil ->
          handle_evaluate(scope, owner, task, frame)

        handoff_id ->
          result =
            CodeMySpec.Agents.CompletionHandoffs.complete(
              scope,
              caller_agent_id,
              task.id,
              handoff_id,
              params
            )

          response =
            case result do
              {:ok, handoff} ->
                Anubis.Server.Response.tool()
                |> Anubis.Server.Response.text(
                  CodeMySpec.Agents.CompletionHandoffs.message(handoff)
                )

              {:error, reason} ->
                TasksMapper.error(reason)
            end

          {:reply, response, frame}
      end
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
      result = dispatch_evaluate(task_module, scope, task, owner)

      case result do
        {:ok, :valid} ->
          {:ok, _} = TaskOwner.complete_task(scope, owner, task.id, :completed)
          clear_feedback(scope, owner, task.id)

          Logger.info(
            "[EvaluateTask] #{type_name(task_module)} passed — task #{task.id} completed"
          )

          {:reply, TasksMapper.evaluate_passed_response(task), frame}

        {:ok, :valid, info} ->
          {:ok, _} = TaskOwner.complete_task(scope, owner, task.id, :completed)
          clear_feedback(scope, owner, task.id)

          Logger.info(
            "[EvaluateTask] #{type_name(task_module)} passed with info — task #{task.id} completed"
          )

          {:reply, TasksMapper.evaluate_passed_response(task, info), frame}

        # The third outcome, and the one this surface was missing. `QaStory`
        # answers it for a task a sub-agent owns and has not submitted for yet.
        # `TaskEvaluator` has had a clause for it since it was introduced; here
        # it fell through the `case` and raised, so the caller got a bare
        # "Internal error" and retried it (`229a42e7`).
        {:ok, :skip, why} ->
          Logger.info(
            "[EvaluateTask] #{type_name(task_module)} left task #{task.id} active: #{why}"
          )

          {:reply, TasksMapper.evaluate_skipped_response(task, why), frame}

        # Waiting on something that reports back — `PromoteWork` with analysis
        # running at the commit it would merge (28d72f8a). Open, and not
        # feedback: nothing needs fixing until the result lands.
        {:ok, :pending, why} ->
          Logger.info("[EvaluateTask] #{type_name(task_module)} pending on task #{task.id}")
          {:reply, TasksMapper.evaluate_pending_response(task, why), frame}

        {:ok, :invalid, feedback} ->
          record_feedback(scope, owner, task.id, feedback)
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
  # `owner` is offered to any module that wants it, because some answers depend
  # on *who* is asking rather than on what the task says.
  #
  # `Task.agent_id` cannot carry that: `Agent.add_task/2` deliberately leaves it
  # nil — "the list a task is in says who owns it" — and on a session's task the
  # field means the Claude Code sub-agent it was assigned to. A module reading it
  # as "is this one of ours" is wrong in both directions, which is how an agent
  # in our own BEAM came to be told to `curl` a harness id this machine does not
  # serve (it should have been told to stop and wait to be notified).
  #
  # Loaded first: `function_exported?/3` answers false for a module that has not
  # been loaded yet, and in interactive mode (dev, test) a task module nobody has
  # touched since boot is not. A held `bdd_specs_passing` task's `FixBddSpecs`
  # fell through to its read-only `evaluate/2` on exactly that, answering "not
  # certified" without ever certifying (2026-10-02).
  defp dispatch_evaluate(module, scope, task, owner) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, :evaluate, 3) -> module.evaluate(scope, task, owner)
      Evaluator.has_custom_evaluate?(module) -> module.evaluate(scope, task)
      true -> Evaluator.evaluate(scope, task)
    end
  rescue
    e -> {:error, "Evaluation failed: #{Exception.message(e)}"}
  end

  defp record_feedback(scope, %Session{} = session, _task_id, feedback),
    do: Sessions.record_eval_feedback(scope, session, feedback)

  defp record_feedback(scope, owner, task_id, feedback),
    do: TaskOwner.record_task_feedback(scope, owner, task_id, feedback)

  defp clear_feedback(scope, %Session{} = session, _task_id),
    do: Sessions.clear_eval_feedback(scope, session)

  defp clear_feedback(scope, owner, task_id),
    do: TaskOwner.clear_task_feedback(scope, owner, task_id)

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
