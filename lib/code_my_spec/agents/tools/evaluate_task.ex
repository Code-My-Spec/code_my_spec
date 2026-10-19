defmodule CodeMySpec.Agents.Tools.EvaluateTask do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.AgentTasks.Evaluator
  alias CodeMySpec.Agents.Tools.TaskResponses, as: TasksMapper
  alias CodeMySpec.TaskOwner

  @impl true
  def name, do: "evaluate_task"

  @impl true
  def description do
    """
    Evaluate a task's work and get pass/fail feedback.

    Call this when you've completed the work for a task with manual validation.
    The task's module evaluates your work against its criteria.

    On pass: the task is marked completed and the requirement is rechecked.
    On fail: you receive feedback describing what needs fixing.

    Tasks with automatic validation are evaluated by the stop hook — you don't
    need to call this for those.

    The `session_id` is injected automatically by the PreToolUse hook.
    """
  end

  @impl true
  def params do
    %{
      session_id: {:meta, :string, [description: "Injected by hook — do not set manually"]},
      agent_id:
        {:meta, :string,
         [
           description:
             "Whose task to close. An agent we run carries it on the connection and omits this."
         ]},
      verification:
        {:meta, :string,
         [description: "Observed artifact and parent-gitlink verification; never a QA verdict."]},
      task_id: {:required, {:meta, :string, [description: "Task ID to evaluate"]}},
      artifact_sha: :string,
      parent_commit: :string,
      parent_gitlink: :string,
      handoff_id:
        {:meta, :string,
         [
           description:
             "Report assigned artifact completion instead of evaluating; does not close the task or launch validation."
         ]}
    }
  end

  @impl true
  def call(%{task_id: task_id} = params, context) do
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
    caller_agent_id = context[:agent_id] || Map.get(params, :agent_id)
    session_id = Map.get(params, :session_id)

    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, owner} <- resolve_owner(scope, session_id, caller_agent_id),
         {:ok, task} <- find_task(owner, task_id) do
      case Map.get(params, :handoff_id) do
        nil ->
          handle_evaluate(scope, owner, task, context)

        handoff_id ->
          result =
            CodeMySpec.Agents.CompletionHandoffs.complete(
              scope,
              caller_agent_id,
              task.id,
              handoff_id,
              params
            )

          completion_response(result)
      end
    else
      {:error, :no_owner} ->
        TasksMapper.error(Agents.no_owner_message())

      {:error, :task_not_found} ->
        TasksMapper.task_not_found(task_id)

      {:error, reason} ->
        TasksMapper.error(reason)
    end
  end

  defp completion_response({:ok, handoff}) do
    {:ok, CodeMySpec.Agents.CompletionHandoffs.message(handoff)}
  end

  defp completion_response({:error, reason}), do: TasksMapper.error(reason)

  # Every task is owned by an agent: the one on the connection, else the
  # terminal agent the hook's `session_id` names.
  defp resolve_owner(scope, session_id, agent_id),
    do: Agents.fetch_owner(scope, agent_id, session_id)

  defp find_task(owner, task_id) do
    case TaskOwner.find_task(owner, task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, task}
    end
  end

  defp handle_evaluate(_scope, _owner, %{status: status}, _context)
       when status in [:completed, :failed, :cancelled] do
    TasksMapper.task_already_terminal(status)
  end

  defp handle_evaluate(scope, owner, task, _context) do
    task_module = task.session_type

    if is_nil(task_module) do
      TasksMapper.error("No task module configured for this task")
    else
      result = dispatch_evaluate(task_module, scope, task, owner)

      case result do
        {:ok, :valid} ->
          {:ok, _} = TaskOwner.complete_task(scope, owner, task.id, :completed)
          clear_feedback(scope, owner, task.id)

          Logger.info(
            "[EvaluateTask] #{type_name(task_module)} passed — task #{task.id} completed"
          )

          TasksMapper.evaluate_passed_response(task)

        {:ok, :valid, info} ->
          {:ok, _} = TaskOwner.complete_task(scope, owner, task.id, :completed)
          clear_feedback(scope, owner, task.id)

          Logger.info(
            "[EvaluateTask] #{type_name(task_module)} passed with info — task #{task.id} completed"
          )

          TasksMapper.evaluate_passed_response(task, info)

        # The third outcome, and the one this surface was missing. `QaStory`
        # answers it for a task a sub-agent owns and has not submitted for yet.
        # `TaskEvaluator` has had a clause for it since it was introduced; here
        # it fell through the `case` and raised, so the caller got a bare
        # "Internal error" and retried it (`229a42e7`).
        {:ok, :skip, why} ->
          Logger.info(
            "[EvaluateTask] #{type_name(task_module)} left task #{task.id} active: #{why}"
          )

          TasksMapper.evaluate_skipped_response(task, why)

        # Waiting on something that reports back — `PromoteWork` with analysis
        # running at the commit it would merge (28d72f8a). Open, and not
        # feedback: nothing needs fixing until the result lands.
        {:ok, :pending, why} ->
          Logger.info("[EvaluateTask] #{type_name(task_module)} pending on task #{task.id}")
          TasksMapper.evaluate_pending_response(task, why)

        {:ok, :invalid, feedback} ->
          record_feedback(scope, owner, task.id, feedback)
          Logger.info("[EvaluateTask] #{type_name(task_module)} failed — feedback returned")
          TasksMapper.evaluate_needs_work_response(task, feedback)

        {:error, reason} ->
          Logger.warning("[EvaluateTask] #{type_name(task_module)} error: #{inspect(reason)}")
          TasksMapper.evaluate_error_response(task, reason)
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

  defp record_feedback(scope, owner, task_id, feedback),
    do: TaskOwner.record_task_feedback(scope, owner, task_id, feedback)

  defp clear_feedback(scope, owner, task_id),
    do: TaskOwner.clear_task_feedback(scope, owner, task_id)

  defp type_name(module) do
    module |> Atom.to_string() |> String.split(".") |> List.last()
  end
end
