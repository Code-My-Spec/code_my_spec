defmodule CodeMySpec.Validation.RunReconciled do
  @moduledoc """
  Re-evaluates the active sessions' tasks when an analysis run lands.

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

  alias CodeMySpec.Sessions
  alias CodeMySpec.Validation.TaskEvaluator

  @event [:code_my_spec, :analysis, :run_reconciled]

  @doc "Attach the handler. Called once, after the application tree starts."
  def attach do
    :telemetry.attach({__MODULE__, :evaluate}, @event, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(@event, _measurements, %{scope: scope}, _config) do
    scope
    |> Sessions.list_active_sessions()
    |> Enum.each(fn session ->
      TaskEvaluator.evaluate_session(scope, session, record_feedback: false, sync: false)
    end)
  catch
    kind, reason ->
      Logger.warning(
        "[Analysis] session evaluation failed: #{Exception.format_banner(kind, reason)}"
      )
  end
end
