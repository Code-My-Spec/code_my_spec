defmodule CodeMySpecSpex.Story1080.Criterion2220Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2220 — An agent that claims and cancels the same work three
  times is not pushed that work again and main is told, with the offer
  left open as escalated, not declined; a single claim-and-cancel returns
  the work to be offered again.

  Per product's ruling on issue 75783a94 (criterion 1815): a claim-cancel
  is not a decline. `Offers.outcome/3`'s old guard that settled a
  claimed-then-cancelled offer straight to `:declined` is replaced by this
  criterion's own escalation (`cycle_outcome/1`): the first two claim-cancel
  cycles on the same subject settle `:cancelled` and return the work to be
  offered again; the third escalates exactly as an offer exhausted by
  ignoring does (criterion 2169) -- open, held back, main told once.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1, start_session: 1]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.CancelTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.WorkingCopies
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

  spex "A third claim-cancel cycle holds the work back and tells main once; one cycle returns it",
       criterion: 2220 do
    scenario "a coder claims and cancels the same work three times in a row" do
      given_ "coding work waiting, a continuous coder, and a continuous main mid-turn", context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = HarnessHooks.ensure_live_harness(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = context |> start_session() |> put_to_work()
        id = coder.id
        assert_receive {:work_turn_requested, ^id, _ref, _first}, 2_000

        {:ok, Map.merge(context, %{coder: id, main_id: main.id})}
      end

      when_ "it claims and cancels that work once", context do
        {:ok, claim_and_cancel(context, context.coder)}
      end

      then_ "that cycle settles cancelled, not declined, and the work is offered again",
            context do
        id = context.coder

        assert_receive {:work_turn_requested, ^id, _ref, _again}, 2_000,
                       "a single claim-cancel did not return the work to be offered again"

        [_fresh, cycle_one | _] = offers(context, id, %{kind: "work"})
        assert cycle_one.status == "cancelled"
        {:ok, context}
      end

      when_ "it claims and cancels that same work a second time", context do
        {:ok, claim_and_cancel(context, context.coder)}
      end

      then_ "that second cycle also settles cancelled, and the work is offered again still",
            context do
        id = context.coder

        assert_receive {:work_turn_requested, ^id, _ref, _again}, 2_000,
                       "a second claim-cancel did not return the work to be offered again"

        [_fresh, cycle_two, cycle_one | _] = offers(context, id, %{kind: "work"})
        assert cycle_two.status == "cancelled"
        assert cycle_one.status == "cancelled"
        {:ok, context}
      end

      when_ "it claims and cancels that same work a third time", context do
        {:ok, claim_and_cancel(context, context.coder)}
      end

      then_ "the third cycle holds the work back: not pushed again, open, not declined",
            context do
        id = context.coder

        refute_receive {:work_turn_requested, ^id, _ref, _again}, 1_000,
                        "work escalated after a third claim-cancel cycle was pushed again"

        # `next_step` (the raw field driving the escalation) isn't on the
        # text listing `offers/2` parses -- `note` is what that listing
        # shows once main has been told about a held-back offer, written by
        # the same tell_main_held_back path that reads next_step.
        [escalated | _] = offers(context, id, %{kind: "work"})
        assert escalated.status == "open"
        assert escalated.note == "told_main"
        {:ok, context}
      end

      then_ "main is told once about the escalation", context do
        main_id = context.main_id
        coder = context.coder
        assert_receive {:agent_dispatch, ^main_id, _ref, notice}, 2_000
        assert notice =~ coder, notice
        {:ok, context}
      end
    end
  end

  # Not IdleAgentHelpers.start_agent_task/3 + held_task_id/2: held_task_id's
  # ListTasks-text regex grabs the first UUID it finds, which is the prior
  # cycle's already-cancelled task once a second task exists on the agent.
  # Reading the id straight off this call's own reply sidesteps that.
  defp claim_and_cancel(context, id) do
    {:reply, started, _} = StartTask.execute(next_task(context, id), agent_frame(context, id))
    refute started.isError, response_text(started)
    task_id = extract_task_id!(started)

    {:reply, cancelled, _} = CancelTask.execute(%{task_id: task_id}, agent_frame(context, id))
    refute cancelled.isError, response_text(cancelled)

    :ok = Fixtures.end_turn(context.scope, id)
    put_to_work(context)
  end
end
