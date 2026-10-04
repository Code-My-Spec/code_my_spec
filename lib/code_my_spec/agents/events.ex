defmodule CodeMySpec.Agents.Events do
  @moduledoc """
  What Agents does when something below it happens.

  Agents sits above Validation, TaskOwner, Qa, Promotion and Notifications
  (John, 2026-10-04). Those contexts announce what happened as `:telemetry`
  events instead of calling up into Agents; this module, attached at app start,
  answers them. A handler runs synchronously in the emitting process, so a
  handler behaves like the direct call it replaced, and each one rescues and
  logs because telemetry permanently detaches a handler that raises.
  """

  require Logger

  alias CodeMySpec.Agents.Work

  @task_completed [:code_my_spec, :tasks, :completed]
  @task_released [:code_my_spec, :tasks, :released]

  @doc "Attach every handler. Called once, after the application tree starts."
  def attach do
    :telemetry.attach_many(
      {__MODULE__, :handlers},
      [@task_completed, @task_released],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  # A completed task can unblock work for the copy's other agents. Off the
  # caller's process: a missed nudge is the acceptable failure, and the next
  # completion sends it again.
  def handle_event(@task_completed, _measurements, meta, _config) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Work.consider_copy(meta.scope, meta.working_copy_id, :task_completed, meta.except_agent_id)
    end)

    :ok
  rescue
    e -> log(:task_completed, e)
  end

  # A task released from a block. An agent busy on another task is told, not
  # offered (story 1080); `Work` offers it back once that task is done.
  def handle_event(@task_released, _measurements, %{deferred: notice} = meta, _config) do
    Work.note_released(meta.agent, notice)
  rescue
    e -> log(:task_released, e)
  end

  def handle_event(@task_released, _measurements, meta, _config) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Work.wake_released(meta.scope, meta.agent, meta.released, meta.header, meta.detail,
        subject: meta.subject
      )
    end)

    :ok
  rescue
    e -> log(:task_released, e)
  end

  defp log(event, e) do
    Logger.warning("[Agents.Events] #{event} failed: #{Exception.message(e)}")
    :ok
  end
end
