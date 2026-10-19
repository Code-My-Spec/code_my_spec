defmodule CodeMySpec.AgentTasks.RunReconciled do
  @moduledoc """
  Re-evaluates the terminal agents' active tasks when an analysis run lands.

  `Analysis` announces a reconciled run as `[:code_my_spec, :analysis,
  :run_reconciled]` rather than calling `TaskEvaluator` itself (John,
  2026-09-27: run completion is an event, attached at app start). The handler
  runs synchronously in the reconciler, as the direct call did.

  Feedback recording is suppressed: a background re-evaluation repeating the
  same failure text must not advance the R8 stuck counter. `sync: false` — a
  second full sync's missing-files sweep would race the problems just
  reconciled.
  """

  require Logger

  alias CodeMySpec.AgentTasks.TaskEvaluator
  alias CodeMySpec.TaskOwner

  @event [:code_my_spec, :analysis, :run_reconciled]

  @doc "Attach the handler. Called once, after the application tree starts."
  def attach do
    :telemetry.attach({__MODULE__, :evaluate}, @event, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(@event, _measurements, %{scope: scope}, _config) do
    scope
    |> TaskOwner.terminal_agents_with_active_task()
    |> Enum.each(fn agent ->
      TaskEvaluator.evaluate_agent(scope, agent, record_feedback: false, sync: false)
    end)
  catch
    kind, reason ->
      Logger.warning(
        "[Analysis] agent evaluation failed: #{Exception.format_banner(kind, reason)}"
      )
  end
end
