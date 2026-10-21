defmodule CodeMySpec.AgentTasks.TaskEvaluator do
  @moduledoc """
  Evaluates an agent's active task against its requirement, and completes,
  cancels or leaves it according to the answer.

  Evaluation only: no file sync, no compilation, no static analysis — that is
  `Validation.validate_stop/3`'s job.

  See knowledge/tools, "Task evaluation".
  """

  require Logger

  alias CodeMySpec.AgentTasks.Evaluator
  alias CodeMySpec.Environments
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Users.Scope

  @doc """
  Evaluate the active task an agent holds.

  ## Options

  - `:record_feedback` (default `true`) — whether an invalid result bumps the
    task's repeat-feedback counter. Background re-evaluations pass `false`:
    only agent-facing stops count toward the stuck threshold.
  """
  @spec evaluate_agent(Scope.t(), Agent.t(), keyword()) ::
          {:ok, :valid} | {:error, String.t()}
  def evaluate_agent(scope, %Agent{} = agent, opts \\ []) do
    case Agent.active_task(agent) do
      nil ->
        {:ok, :valid}

      %{validation_type: :manual} ->
        Logger.info("[TaskEvaluator] Skipping manual validation task")
        {:ok, :valid}

      task ->
        evaluate_task(scope, agent, task, opts)
    end
  end

  @doc """
  Evaluate a single task: dispatch to custom or unified evaluator, complete on pass.
  """
  @spec evaluate_task(Scope.t(), Agent.t(), map(), keyword()) ::
          {:ok, :valid} | {:error, String.t()}
  def evaluate_task(scope, agent, task, opts \\ []) do
    case task.session_type do
      nil ->
        Logger.warning("[TaskEvaluator] Task #{task.id} has no session_type, skipping")
        {:ok, :valid}

      module ->
        type_name = module |> Atom.to_string() |> String.split(".") |> List.last()
        Logger.info("[TaskEvaluator] Evaluating task #{task.id} (#{type_name})")

        module
        |> dispatch_evaluate(scope, task, opts)
        |> handle_result(scope, agent, task, type_name, opts)
    end
  end

  # One clause per evaluator outcome.
  defp handle_result({:ok, :valid}, scope, agent, task, _type_name, _opts) do
    TaskOwner.complete_task(scope, agent, task.id, :completed)
    TaskOwner.clear_task_feedback(scope, agent, task.id)
    reconsider_other_agents(scope, agent)
    {:ok, :valid}
  end

  # Satisfied with a non-blocking advisory (e.g. ArchitectureDesign's proposal
  # warnings). Completes like `{:ok, :valid}`; the advisory is only logged.
  defp handle_result({:ok, :valid, advisory}, scope, agent, task, _type_name, _opts) do
    Logger.info("[TaskEvaluator] Task #{task.id} valid with advisory: #{advisory}")
    TaskOwner.complete_task(scope, agent, task.id, :completed)
    TaskOwner.clear_task_feedback(scope, agent, task.id)
    reconsider_other_agents(scope, agent)
    {:ok, :valid}
  end

  # Not this stop's task to judge: it stays active for its owner and this stop
  # is not blocked. Neither completing nor failing is right for, e.g., a
  # sub-agent's in-flight task.
  defp handle_result({:ok, :skip, why}, _scope, _agent, task, _type_name, _opts) do
    Logger.info("[TaskEvaluator] Leaving task #{task.id} active: #{why}")
    {:ok, :valid}
  end

  # Bump (or reset) the task's repeat counter, which `Hooks.Stop` reads to
  # detect a stuck loop.
  defp handle_result({:ok, :invalid, feedback}, scope, agent, task, _type_name, opts) do
    if Keyword.get(opts, :record_feedback, true) do
      TaskOwner.record_task_feedback(scope, agent, task.id, feedback)
    end

    {:error, feedback}
  end

  # The task's component or story no longer exists: cancel it and let the
  # agent pull a fresh one.
  defp handle_result({:error, :entity_missing}, scope, agent, task, _type_name, _opts) do
    Logger.info("[TaskEvaluator] Cancelling orphaned task #{task.id} — entity missing")
    TaskOwner.complete_task(scope, agent, task.id, :cancelled)
    {:ok, :valid}
  end

  # The same orphan, said with a message. The evaluating scope is the task's own
  # agent's, so not-found here means gone, not "wrong project"; failing
  # instead would block every stop on work that no longer exists.
  defp handle_result({:error, {kind, _message}}, scope, agent, task, _type_name, _opts)
       when kind in [:story_not_found, :component_not_found] do
    Logger.info("[TaskEvaluator] Cancelling orphaned task #{task.id} — #{kind}")
    TaskOwner.complete_task(scope, agent, task.id, :cancelled)
    {:ok, :valid}
  end

  # The marker text tells a crash apart from a legitimate "not met".
  defp handle_result(
         {:error, {:evaluator_crashed, detail}},
         _scope,
         _agent,
         _task,
         _type_name,
         _opts
       ) do
    {:error,
     """
     ⚠️ Evaluator crashed (not a requirement failure) — this is a bug in the task's evaluate/2 or a checker it delegates to.

     #{detail}

     Agents: do not retry the task until the underlying bug is fixed. Report to the user.
     """}
  end

  # "Could not look" is not "not met", but it still blocks: an allowed stop
  # carries no text, so allowing would wave through an unverified requirement
  # silently. The feedback names the task, type and working copy so the agent
  # can route around it. Any other error is named the same way.
  # See knowledge/tools, "Unobservable environments".
  defp handle_result({:error, reason}, scope, _agent, task, type_name, _opts) do
    if Environments.unobservable?(reason) do
      Logger.error(
        "[TaskEvaluator] task #{task.id} (#{type_name}) could not be evaluated: " <>
          "#{inspect(reason)} — this server holds no working copy"
      )

      {:error, unobservable_feedback(task, type_name, scope, reason)}
    else
      {:error,
       "Error evaluating #{type_name} (task #{task.id}, working copy " <>
         "#{harness_label(scope)}): #{inspect(reason)}"}
    end
  end

  @doc false
  # Public only so the message can be asserted directly.
  def unobservable_feedback(task, type_name, scope, reason) do
    """
    ⚠️ This requirement could not be checked (not a requirement failure).

    The `#{type_name}` checker for task #{task.id} tried to read the working \
    copy, and this server holds none — every file operation answers \
    `#{inspect(reason)}`. Under a light harness that is normal: the harness \
    watches the files and reports them, and a checker that reads a disk \
    directly has nothing to read here.

    Working copy: #{harness_label(scope)}

    This is a framework bug, not something to fix in the project. The checker \
    needs to read the harness's file report (`Files`) rather than the \
    filesystem, as `WriteBddSpecs` does with `Files.list_files/1`.

    Agents: do not rewrite the work; it is very likely already done. Call \
    `create_issue` with `scope: framework`, naming `#{type_name}`, then ask \
    the user how to proceed.
    """
  end

  defp harness_label(%Scope{active_working_copy_id: nil}), do: "unnamed (no harness on the scope)"
  defp harness_label(%Scope{active_working_copy_id: id}), do: id
  defp harness_label(_scope), do: "unknown"

  # Finishing work wakes the roles it unblocked. Only on completing paths, since
  # only a completed task moves the graph, and never a reason an evaluation
  # fails: a missed nudge is acceptable, and the next completion sends it again.
  # The handler (`Agents.Events`) runs the wake off this process; an in-BEAM
  # agent completes inside the harness channel, and a synchronous call back
  # into that channel would kill it.
  @doc """
  Wake the other agents on `agent`'s working copy after it completed a task.

  The agent that finished is the one excluded: it is told directly and must not
  be offered a turn by its own completion. (This used to pass `task.agent_id`,
  the sub-agent label of an old session-owned task, which is never an
  `Agents.Agent` id, so nobody was ever excluded: issue 4427e406.)
  """
  @spec reconsider_other_agents(Scope.t(), Agent.t()) :: :ok
  def reconsider_other_agents(scope, %Agent{id: agent_id}) do
    case scope.active_working_copy_id do
      nil ->
        :ok

      copy_id ->
        nudge(scope, copy_id, agent_id)
    end
  rescue
    error ->
      Logger.warning(
        "[TaskEvaluator] could not reconsider agent work: " <> Exception.message(error)
      )

      :ok
  end

  # Agents answers this (`Agents.Events`); AgentTasks sits below Agents.
  defp nudge(scope, copy_id, except_agent_id) do
    :telemetry.execute([:code_my_spec, :tasks, :completed], %{}, %{
      scope: scope,
      working_copy_id: copy_id,
      except_agent_id: except_agent_id
    })
  end

  # Custom evaluate/2 modules take no opts; only the unified evaluator honours
  # `sync: false`.
  defp dispatch_evaluate(module, scope, task, opts) do
    if Evaluator.has_custom_evaluate?(module) do
      module.evaluate(scope, task)
    else
      Evaluator.evaluate(scope, task, Keyword.take(opts, [:sync]))
    end
  rescue
    e ->
      stack = __STACKTRACE__

      Logger.error(
        "[TaskEvaluator] Evaluator crashed for #{inspect(module)}: #{Exception.format(:error, e, stack)}"
      )

      detail =
        "#{inspect(e.__struct__)}: #{Exception.message(e)}\n\n" <>
          format_stack_summary(stack)

      {:error, {:evaluator_crashed, detail}}
  end

  defp format_stack_summary(stack) do
    stack
    |> Enum.take(5)
    |> Enum.map_join("\n", fn entry -> "  " <> Exception.format_stacktrace_entry(entry) end)
  end
end
