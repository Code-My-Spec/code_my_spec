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
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
  alias CodeMySpec.Requirements
  alias CodeMySpec.Stories

  @provisioning_failed [:code_my_spec, :provisioning, :failed]
  @task_completed [:code_my_spec, :tasks, :completed]
  @task_released [:code_my_spec, :tasks, :released]
  @issue_qa_passed [:code_my_spec, :qa, :issue_passed]
  @story_qa_passed [:code_my_spec, :qa, :story_passed]
  @promotion_team_free [:code_my_spec, :promotion, :team_free]
  @promotion_report [:code_my_spec, :promotion, :report]
  @decline_cleared [:code_my_spec, :notifications, :decline_cleared]
  @tap_out_denied [:code_my_spec, :notifications, :tap_out_denied]
  @decision_reached [:code_my_spec, :notifications, :decision_reached]
  @answer_reached [:code_my_spec, :notifications, :answer_reached]
  @escalated_answer_reached [:code_my_spec, :notifications, :escalated_answer_reached]

  @doc "Attach every handler. Called once, after the application tree starts."
  def attach do
    :telemetry.attach_many(
      {__MODULE__, :handlers},
      [
        @provisioning_failed,
        @task_completed,
        @task_released,
        @issue_qa_passed,
        @story_qa_passed,
        @promotion_team_free,
        @promotion_report,
        @decline_cleared,
        @tap_out_denied,
        @decision_reached,
        @answer_reached,
        @escalated_answer_reached
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event(@provisioning_failed, _measurements, %{scope: scope, step: step}, _config) do
    CodeMySpec.Agents.ProvisioningFailure.deliver(scope, step)
  catch
    kind, reason -> log(:provisioning_failed, kind, reason)
  end

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
        subject: meta.subject,
        outcome: meta.outcome
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

  # A story whose QA passed with nothing left to land finishes here: it was
  # already on main, so no promotion is coming to announce the team free. Story
  # 1016 passed QA at 04:45 with its work on main and team 2 sat idle for seven
  # hours, main never told (2026-10-13). One that still needs promoting is
  # freed by its landing instead.
  def handle_event(@story_qa_passed, _measurements, %{scope: scope, story_id: id}, _config) do
    with %{working_copy_id: copy_id} = story when is_binary(copy_id) <-
           Stories.get_story(scope, id),
         at_copy = %{scope | active_working_copy_id: copy_id},
         true <-
           Requirements.satisfied_now?(at_copy, %{
             entity_type: "story",
             entity_id: id,
             name: "story_promoted"
           }) do
      Assignment.notify_team_free(scope, copy_id, story)
    else
      _ -> :ok
    end
  catch
    kind, reason -> log(:story_qa_passed, kind, reason)
  end

  # A story finished by promotion offers main the same team-free kind an issue
  # finishing through QA does (criterion 1892).
  #
  # Retried across the dev server's code reload. The notice fires as the batch
  # merges into the checkout that server runs, and a module the reloader is
  # swapping at that instant is undefined: team 2 sat idle for 40 minutes after
  # 1066 landed, its notice lost to one (2026-10-14). Both calls are
  # idempotent, so running them again is safe.
  def handle_event(@promotion_team_free, _measurements, meta, _config) do
    across_reload(:promotion_team_free, fn ->
      Assignment.close_promotion_tasks(meta.scope, meta.working_copy_id, meta.story)
      Assignment.notify_team_free(meta.scope, meta.working_copy_id, meta.story)
    end)
  end

  # 1d65a84e: a promotion's outcome -- landed or ejected -- is what an agent's
  # open promote_issue/story_promoted task waits on, so both are admitted to
  # the durable mailbox unconditionally -- not held, and not lost, if the agent
  # cannot be woken for it this instant.
  def handle_event(@promotion_report, _measurements, %{what: what} = meta, _config)
      when what in ["promotion landed", "promotion ejected"] do
    Agents.notify_landed(meta.scope, meta.agent_id, meta.text)
  catch
    kind, reason -> log(:promotion_report, kind, reason)
  end

  # Logged rather than retried: the agent may already be acting on the first
  # message, and a delivery loop does not fix that.
  def handle_event(@promotion_report, _measurements, meta, _config) do
    if meta.what != "restart confirmation" or awaiting_promotion?(meta.scope, meta.agent_id) do
      dispatch_promotion_report(meta)
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
    case Work.offer_turn_with(
           meta.scope,
           meta.agent,
           meta.notice,
           :blocker_resolved,
           meta.subject
         ) do
      {:ok, ref} when is_binary(ref) ->
        :ok

      _not_admissible ->
        meta.agent
        |> Conversations.record_sent_to_agent(meta.notice)
        |> Offers.record(meta.agent, :denial, meta.subject)

        # Exclude this agent: it was just told directly above, on its own
        # thread. Without the exclusion, if the same not-admissible window
        # clears between here and consider_copy's own read, this agent is
        # found idle with the same work still claimable and pushed a second,
        # detail-less turn on the very denial offer just recorded for it --
        # the same self-nudge shape fixed in wake_with_notice/4 (criterion
        # 1799).
        Work.consider_copy(meta.scope, meta.working_copy_id, :tap_out_denied, meta.agent.id)
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

  # Idle: an offered turn. One whose process is not up yet (a restart) gets it
  # on its thread instead: offer-only recorded the answer nowhere and the asker
  # waited on an answered question (2026-10-15). One not in the loop still
  # collects it with `check_answer`.
  def handle_event(@answer_reached, _measurements, meta, _config) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      deliver =
        case Wake.allow?(meta.scope, meta.agent, :question_answered) do
          {:hold, :not_running} -> &Work.wake_with_notice/5
          _ -> &Work.offer_turn_with/5
        end

      deliver.(
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

  def handle_event(@escalated_answer_reached, _measurements, meta, _config) do
    case MainAgent.escalator(meta.scope, meta.asker, meta.escalated_by) do
      nil -> :ok
      agent -> _ = Agents.send_to_agent(agent.id, meta.text, :own_reply)
    end

    :ok
  catch
    kind, reason -> log(:escalated_answer_reached, kind, reason)
  end

  # `catch`, not `rescue`: an exit (a sandbox owner gone, a call timing out)
  # would otherwise detach this handler for every later event.
  defp awaiting_promotion?(scope, agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, agent} ->
        Enum.any?(CodeMySpec.TaskOwner.tasks(agent), fn task ->
          task.requirement_name in ["story_promoted", "promote_issue"] and
            task.status in [:active, :prepared, :blocked]
        end)

      _ ->
        false
    end
  end

  defp dispatch_promotion_report(meta) do
    opts =
      if meta.what == "restart confirmation",
        do: [sender_id: "promotion-notice"],
        else: []

    case Agents.dispatch_message(meta.scope, meta.agent_id, meta.text, :own_reply, 15_000, opts) do
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

  @reload_attempts 4
  @reload_settle_ms 3_000

  @doc """
  Run `fun`, trying again off the caller when a module is undefined because
  the dev server's code reloader is swapping it. Any other failure is logged
  with its stacktrace. For idempotent handlers only.
  """
  @spec across_reload(atom(), (-> term()), pos_integer(), non_neg_integer()) :: :ok
  def across_reload(event, fun, attempt \\ 1, settle_ms \\ @reload_settle_ms) do
    fun.()
    :ok
  catch
    kind, reason ->
      if mid_reload?(kind, reason) and attempt < @reload_attempts do
        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          Process.sleep(settle_ms)
          across_reload(event, fun, attempt + 1, settle_ms)
        end)

        :ok
      else
        log(event, kind, reason, __STACKTRACE__)
      end
  end

  defp mid_reload?(:error, :undef), do: true
  defp mid_reload?(:error, %UndefinedFunctionError{}), do: true
  defp mid_reload?(_kind, _reason), do: false

  defp log(event, kind, reason, stacktrace) do
    Logger.warning(
      "[Agents.Events] #{event} failed: #{Exception.format(kind, reason, stacktrace)}"
    )

    :ok
  end

  defp log(event, kind, reason) do
    Logger.warning("[Agents.Events] #{event} failed: #{Exception.format_banner(kind, reason)}")
    :ok
  end
end
