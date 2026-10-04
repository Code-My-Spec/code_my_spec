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

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.Agents.Work

  @task_completed [:code_my_spec, :tasks, :completed]
  @task_released [:code_my_spec, :tasks, :released]
  @issue_qa_passed [:code_my_spec, :qa, :issue_passed]
  @promotion_team_free [:code_my_spec, :promotion, :team_free]
  @promotion_report [:code_my_spec, :promotion, :report]

  @doc "Attach every handler. Called once, after the application tree starts."
  def attach do
    :telemetry.attach_many(
      {__MODULE__, :handlers},
      [
        @task_completed,
        @task_released,
        @issue_qa_passed,
        @promotion_team_free,
        @promotion_report
      ],
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

  # An issue's QA passed: its team is free for other work.
  def handle_event(@issue_qa_passed, _measurements, meta, _config) do
    IssueAssignment.free(meta.scope, meta.issue)
  rescue
    e -> log(:issue_qa_passed, e)
  end

  # A story finished by promotion offers main the same team-free kind an issue
  # finishing through QA does (criterion 1892).
  def handle_event(@promotion_team_free, _measurements, meta, _config) do
    Assignment.notify_team_free(meta.scope, meta.working_copy_id, meta.story)
  rescue
    e -> log(:promotion_team_free, e)
  end

  # Logged rather than retried: the agent may already be acting on the first
  # message, and a delivery loop does not fix that.
  def handle_event(@promotion_report, _measurements, meta, _config) do
    case Agents.dispatch_message(meta.scope, meta.agent_id, meta.text, :own_reply) do
      {:ok, disposition, _message} ->
        Logger.info("[Promotion] #{meta.what} #{disposition} to agent #{meta.agent_id}")

      {:error, deliver_error} ->
        Logger.warning(
          "[Promotion] #{meta.what} could not be delivered to agent #{meta.agent_id}: " <>
            inspect(deliver_error)
        )
    end
  rescue
    e -> log(:promotion_report, e)
  end

  defp log(event, e) do
    Logger.warning("[Agents.Events] #{event} failed: #{Exception.message(e)}")
    :ok
  end
end
