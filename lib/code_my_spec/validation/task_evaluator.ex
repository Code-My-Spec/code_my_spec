defmodule CodeMySpec.Validation.TaskEvaluator do
  @moduledoc """
  Evaluates agent tasks against their requirements.

  Pure evaluation: reads DB, decides pass/fail. No file sync, no compilation,
  no static analysis — that's `Validation.validate_stop/3`'s job.
  """

  require Logger

  alias CodeMySpec.AgentTasks.Evaluator
  alias CodeMySpec.Environments
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

  # Replies that mean "this server could not observe the working copy", as
  # opposed to "the requirement is unmet". `Environments` returns these from
  # every file operation when `scope.environment` is nil, which under a light
  # harness is the steady state rather than an edge case: the server has no
  # disk by construction, and the harness is what watches the files.
  # `Environments.unobservable?/1` is the list now, because it is what produces
  # these — so a checker deciding whether to flatten one into a verdict asks the
  # same question this does. A second copy would drift, and the drift is silent:
  # the branch below just stops being reached (074b7c83).

  @doc """
  Look up session by external conversation ID, evaluate the active task.
  """
  @spec evaluate_sessions(Scope.t(), String.t()) :: {:ok, :valid} | {:error, String.t()}
  def evaluate_sessions(%Scope{} = scope, session_id) when is_binary(session_id) do
    case Sessions.get_by_external_id(scope, session_id) do
      nil ->
        {:ok, :valid}

      %Session{} = session ->
        evaluate_session(scope, session)
    end
  end

  @doc """
  Evaluate the active task on a session.

  ## Options

  - `:record_feedback` (default `true`) — whether an invalid result bumps the
    session's R8 repeat-feedback counter. Background re-evaluations (analysis
    Reconciler) pass `false`: repeating the same failure text from a
    background run must not advance the stuck counter — only agent-facing
    stops count.
  """
  @spec evaluate_session(Scope.t(), Session.t(), keyword()) ::
          {:ok, :valid} | {:error, String.t()}
  def evaluate_session(scope, session, opts \\ []) do
    case Session.active_task(session) do
      nil ->
        {:ok, :valid}

      %{validation_type: :manual} ->
        Logger.info("[TaskEvaluator] Skipping manual validation task")
        {:ok, :valid}

      task ->
        evaluate_task(scope, session, task, opts)
    end
  end

  @doc """
  Evaluate a single task: dispatch to custom or unified evaluator, complete on pass.
  """
  @spec evaluate_task(Scope.t(), Session.t(), map(), keyword()) ::
          {:ok, :valid} | {:error, String.t()}
  def evaluate_task(scope, session, task, opts \\ []) do
    case task.session_type do
      nil ->
        Logger.warning("[TaskEvaluator] Task #{task.id} has no session_type, skipping")
        {:ok, :valid}

      module ->
        type_name = module |> Atom.to_string() |> String.split(".") |> List.last()
        Logger.info("[TaskEvaluator] Evaluating task #{task.id} (#{type_name})")

        module
        |> dispatch_evaluate(scope, task, opts)
        |> handle_result(scope, session, task, type_name, opts)
    end
  end

  # One clause per outcome rather than one `case` inside an `if`. The branches
  # were only going to keep accruing — this is where `:no_environment` had to be
  # told apart from a requirement failure — and each new one deepened the same
  # body instead of standing on its own.
  defp handle_result({:ok, :valid}, scope, session, task, _type_name, _opts) do
    Sessions.complete_task(scope, session, task.id, :completed)
    Sessions.clear_eval_feedback(scope, session)
    {:ok, :valid}
  end

  # Satisfied with a non-blocking advisory (e.g. ArchitectureDesign's "component
  # preserved in DB" warnings). Completes exactly like {:ok, :valid} — the
  # advisory already surfaced during the run (execute_proposal output). The MCP
  # `evaluate_task` tool returns it to the agent; the stop hook just logs it.
  defp handle_result({:ok, :valid, advisory}, scope, session, task, _type_name, _opts) do
    Logger.info("[TaskEvaluator] Task #{task.id} valid with advisory: #{advisory}")
    Sessions.complete_task(scope, session, task.id, :completed)
    Sessions.clear_eval_feedback(scope, session)
    {:ok, :valid}
  end

  # Not this stop's task to judge, so it stays active.
  #
  # The third answer. `:valid` completes and `:invalid` files feedback, and an
  # evaluator that wanted neither had to pick one anyway: `QaStory` returned
  # `:valid` for a sub-agent's in-flight task, which completed it out from under
  # the sub-agent before any attempt existed (7f79b855). The compensating fix
  # was to mark `qa_complete` manual, which skipped this module entirely — and
  # took the whole stop gate with it, because a session holding a manual task
  # never reaches validation at all.
  #
  # So the outcome the guard always needed: do nothing, successfully. The task
  # stays active for whoever owns it, and this stop is not blocked on it.
  defp handle_result({:ok, :skip, why}, _scope, _session, task, _type_name, _opts) do
    Logger.info("[TaskEvaluator] Leaving task #{task.id} active: #{why}")
    {:ok, :valid}
  end

  # R8: hash the feedback and bump (or reset) the session-level repeat counter
  # so stop_controller can detect a stuck loop (same hash 5 times → terminate).
  defp handle_result({:ok, :invalid, feedback}, scope, session, _task, _type_name, opts) do
    if Keyword.get(opts, :record_feedback, true) do
      Sessions.record_eval_feedback(scope, session, feedback)
    end

    {:error, feedback}
  end

  # Component or story this task points at no longer exists (likely removed by
  # ComponentSync or a manual purge). The task can't be evaluated, so cancel it
  # and let the session pull a fresh one.
  defp handle_result({:error, :entity_missing}, scope, session, task, _type_name, _opts) do
    Logger.info("[TaskEvaluator] Cancelling orphaned task #{task.id} — entity missing")
    Sessions.complete_task(scope, session, task.id, :cancelled)
    {:ok, :valid}
  end

  # Distinguish crashes from requirement failures. The marker text at the front
  # lets agents (and humans) tell the difference from a legitimate "not met".
  defp handle_result(
         {:error, {:evaluator_crashed, detail}},
         _scope,
         _session,
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

  # The checker could not look, which is not the same as the work not being
  # done — and `Environments`' own moduledoc says so: "'no disk' and 'not there'
  # are now the same reply … which is fine for rendering a prompt and is *not*
  # fine for deciding a requirement is unmet."
  #
  # It still blocks. An allowed stop carries no text — `Stop.allow/2` returns
  # `%{}` — so not blocking would mean waving through a requirement nobody
  # verified, without saying so. Between a stop the agent cannot clear and a
  # stop that quietly claims work is checked when it was not, the first is
  # recoverable.
  #
  # What was missing is everything the agent needed to route around it.
  # `Error: :no_environment` names no task, no requirement, no working copy, and
  # no action.
  #
  # Otherwise: named, rather than an atom on its own. Which task, which type,
  # and which working copy is the difference between a bug report and a dead
  # end.
  defp handle_result({:error, reason}, scope, _session, task, type_name, _opts) do
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
  # Public only so the message can be asserted without standing up a session, a
  # task and a checker that leaks the raw atom. The message *is* the fix here —
  # the branch existed before and said `Error: :no_environment`.
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
    filesystem — see `AgentTasks.WriteBddSpecs.spec_checker/1` for the shape.

    Agents: do not rewrite the work; it is very likely already done. Call \
    `create_issue` with `scope: framework`, naming `#{type_name}`, then ask \
    the user how to proceed.
    """
  end

  defp harness_label(%Scope{active_working_copy_id: nil}), do: "unnamed (no harness on the scope)"
  defp harness_label(%Scope{active_working_copy_id: id}), do: id
  defp harness_label(_scope), do: "unknown"

  # Custom evaluate/2 modules don't take opts; only the unified evaluator
  # honors `sync: false`.
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
