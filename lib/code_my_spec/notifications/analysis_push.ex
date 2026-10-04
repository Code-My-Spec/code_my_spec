defmodule CodeMySpec.Notifications.AnalysisPush do
  @moduledoc """
  Pushes an analysis run's blocking findings to the user's phone.

  Background runs push the outcome when they land error-severity problems —
  the agent may already have stopped, and this is how the result reaches a user
  who walked away. Model-invoked API runs skip it: the caller sees the output.

  `Analysis` announces a reconciled run as `[:code_my_spec, :analysis,
  :run_reconciled]` and this handler, attached at app start, answers it (John,
  2026-09-27: run completion is an event, not a call up into Notifications).
  """

  require Logger

  alias CodeMySpec.Notifications.NotificationClient

  @event [:code_my_spec, :analysis, :run_reconciled]

  @doc "Attach the handler. Called once, after the application tree starts."
  def attach do
    :telemetry.attach({__MODULE__, :push}, @event, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(@event, _measurements, %{notify: true} = meta, _config) do
    errors = Enum.filter(meta.problems, &(&1.severity == :error))

    if errors != [] do
      NotificationClient.notify(%{
        title: "Analysis: #{meta.source} found #{length(errors)} problem(s)",
        body: body(meta.scope, List.first(errors))
      })
    end
  rescue
    e ->
      Logger.warning("[Analysis] notification failed: #{Exception.message(e)}")
  end

  def handle_event(@event, _measurements, _meta, _config), do: :ok

  defp body(scope, problem) do
    project = (scope.active_project && scope.active_project.name) || "project"
    "#{project} — #{problem.file_path}:#{problem.line || "?"}"
  end
end
