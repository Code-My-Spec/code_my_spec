defmodule CodeMySpecSpex.Story1080.Criterion1815Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1815 — A new offer after a claim restarts the attempt count.

  The attempt counts the tries since the agent last took it, so a claim
  resets it: the next offer for the same work starts again at attempt one.

  Per product's ruling (question 4017d97c): a claimed task still holds the
  agent busy, so the same work cannot be re-pushed while it is held --
  `cancel_task` is what un-claims it, and John's rule is that a cancel is not
  a decline, so the work returns to the graph as actionable rather than being
  held back.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.CancelTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "The offer after a claim starts again at attempt one", criterion: 1815 do
    scenario "a coder claims a work offer, cancels the task, then the same work is offered again" do
      given_ "coding work is offered once and goes unclaimed, so the next offer is attempt two",
             context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = HarnessHooks.ensure_live_harness(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = context |> start_session() |> put_to_work()
        id = coder.id
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, Map.put(context, :coder, id)}
      end

      given_ "offered again, it claims the work with start_task", context do
        id = context.coder
        context = put_to_work(context)
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        context = start_agent_task(context, id, next_task(context, id))
        {:ok, Map.put(context, :task_id, held_task_id(context, id))}
      end

      when_ "it cancels that task, ends its turn, and the same work is offered to it again",
            context do
        id = context.coder

        {:reply, cancelled, _} =
          CancelTask.execute(%{task_id: context.task_id}, agent_frame(context, id))

        refute cancelled.isError, response_text(cancelled)

        :ok = Fixtures.end_turn(context.scope, id)
        context = put_to_work(context)

        assert_receive {:work_turn_requested, ^id, _ref, _prompt},
                       2_000,
                       "the work was not offered again after the cancel"

        {:ok, context}
      end

      then_ "the new offer is a fresh record restarting at attempt one, not a reopened decline",
            context do
        # Newest first: the first push (ignored), the claim-then-cancel
        # (criterion 2220's own first cycle: settles :cancelled, not
        # :declined -- John's rule, issue 75783a94), then the fresh offer
        # that followed it.
        assert [fresh, cancelled, ignored] = offers(context, context.coder, %{kind: "work"}),
               "expected the ignored push, the claim-cancel, and a fresh offer after it:\n" <>
                 listing(context)

        assert ignored.status == "ignored"
        assert cancelled.status == "cancelled"
        assert fresh.attempt == 1, "the offer after a cancel did not restart at attempt 1"

        refute Enum.any?([fresh, cancelled, ignored], &(&1.status == "declined")),
               "a cancel must not be recorded as a decline:\n" <> listing(context)

        {:ok, context}
      end
    end
  end
end
