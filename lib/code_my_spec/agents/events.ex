defmodule CodeMySpec.Agents.Events do
  @moduledoc """
  What Agents does when something below it happens.

  Agents sits above Validation, TaskOwner, Qa, Promotion and Notifications
  (John, 2026-10-04). Those contexts announce what happened as `:telemetry`
  events instead of calling up into Agents; this module, attached at app start,
  answers them. A handler runs synchronously in the emitting process, so a
  handler behaves like the direct call it replaced, and each one rescues and
  logs because telemetry permanently detaches a handler that raises or exits.
  """

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations

  @task_completed [:code_my_spec, :tasks, :completed]
  @task_released [:code_my_spec, :tasks, :released]
  @issue_qa_passed [:code_my_spec, :qa, :issue_passed]
  @promotion_team_free [:code_my_spec, :promotion, :team_free]
  @promotion_report [:code_my_spec, :promotion, :report]
  @decline_cleared [:code_my_spec, :notifications, :decline_cleared]
  @tap_out_denied [:code_my_spec, :notifications, :tap_out_denied]
  @decision_reached [:code_my_spec, :notifications, :decision_reached]
  @answer_reached [:code_my_spec, :notifications, :answer_reached]

  @doc "Attach every handler. Called once, after the application tree starts."
  def attach do
    :telemetry.attach_many(
      {__MODULE__, :handlers},
      [
        @task_completed,
        @task_released,
        @issue_qa_passed,
        @promotion_team_free,
        @promotion_report,
        @decline_cleared,
        @tap_out_denied,
        @decision_reached,
        @answer_reached
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
  catch
    kind, reason -> log(:task_completed, kind, reason)
  end

  # A task released from a block. An agent busy on another task is told, not
  # offered (story 1080); `Work` offers it back once that task is done.
  def handle_event(@task_released, _measurements, %{deferred: notice} = meta, _config) do
    Work.note_released(meta.agent, notice)
  catch
    kind, reason -> log(:task_released, kind, reason)
  end

  def handle_event(@task_released, _measurements, meta, _config) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Work.wake_released(meta.scope, meta.agent, meta.released, meta.header, meta.detail,
        subject: meta.subject
      )
    end)

    :ok
  catch
    kind, reason -> log(:task_released, kind, reason)
  end

  # An issue's QA passed: its team is free for other work.
  def handle_event(@issue_qa_passed, _measurements, meta, _config) do
    IssueAssignment.free(meta.scope, meta.issue)
  catch
    kind, reason -> log(:issue_qa_passed, kind, reason)
  end

  # A story finished by promotion offers main the same team-free kind an issue
  # finishing through QA does (criterion 1892).
  def handle_event(@promotion_team_free, _measurements, meta, _config) do
    Assignment.notify_team_free(meta.scope, meta.working_copy_id, meta.story)
  catch
    kind, reason -> log(:promotion_team_free, kind, reason)
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
  catch
    kind, reason -> log(:promotion_report, kind, reason)
  end

  # A person saying "go and work" outranks the agent's own last refusal: the
  # deny IS the answer to that refusal, so the mark is cleared before either
  # wake that follows.
  def handle_event(@decline_cleared, _measurements, meta, _config) do
    {:ok, _cleared} = Work.clear_decline(meta.scope, meta.agent)
    :ok
  catch
    kind, reason -> log(:decline_cleared, kind, reason)
  end

  # In the turn when the agent can take one; recorded when it cannot. An agent
  # mid-turn, reserved, or holding a task still has to be told.
  def handle_event(@tap_out_denied, _measurements, meta, _config) do
    case Work.offer_turn_with(meta.scope, meta.agent, meta.notice, :blocker_resolved, meta.subject) do
      {:ok, ref} when is_binary(ref) ->
        :ok

      _not_admissible ->
        meta.agent
        |> Conversations.record_sent_to_agent(meta.notice)
        |> Offers.record(meta.agent, :denial, meta.subject)

        Work.consider_copy(meta.scope, meta.working_copy_id, :tap_out_denied)
    end
  catch
    kind, reason -> log(:tap_out_denied, kind, reason)
  end

  def handle_event(@decision_reached, _measurements, meta, _config) do
    _ = Agents.send_to_agent(meta.agent_id, meta.text, :own_reply)
    :ok
  catch
    kind, reason -> log(:decision_reached, kind, reason)
  end

  # Mid-turn, the answer arrives as a message; idle, as an offered turn.
  def handle_event(@answer_reached, _measurements, %{scope: nil} = meta, _config) do
    _ =
      Agents.send_to_agent(meta.agent.id, meta.text, :question_answered,
        offer: {:answer, {"question", meta.question_id}}
      )

    :ok
  catch
    kind, reason -> log(:answer_reached, kind, reason)
  end

  def handle_event(@answer_reached, _measurements, meta, _config) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Work.offer_turn_with(
        meta.scope,
        meta.agent,
        meta.text,
        :question_answered,
        {"question", meta.question_id}
      )
    end)

    :ok
  catch
    kind, reason -> log(:answer_reached, kind, reason)
  end

  # `catch`, not `rescue`: an exit (a sandbox owner gone, a call timing out)
  # would otherwise detach this handler for every later event.
  defp log(event, kind, reason) do
    Logger.warning("[Agents.Events] #{event} failed: #{Exception.format_banner(kind, reason)}")
    :ok
  end
end
