defmodule CodeMySpecSpex.Story1080.Criterion2169Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2169 — An offer ignored past its last rung stays open and
  reaches main, naming the agent, the offer and what it asked.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "An offer ignored past its last rung stays open and reaches main", criterion: 2169 do
    scenario "a coder ignores a work offer through every rung" do
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

        # Issue 38686d5d: FullSatisfactionFixtures.apply_up_to_analysis builds
        # a real fixture story ("Reservations user story"), which can leave
        # more than one requirement actionable for this role. The scenario's
        # own subject is whichever one was actually offered first -- pin it,
        # rather than assume a fresh agent's offer list holds only one row.
        [offered] = offers(context, id, %{kind: "work", status: "open"})
        {:ok, Map.merge(context, %{coder: id, main_id: main.id, subject: offered.subject})}
      end

      when_ "it ignores every rung of that offer", context do
        id = context.coder

        # given_ already secured the first push (rung "id"). The ladder for
        # work/requirement is three rungs long: two more ignores climb to
        # "detail" and "alternatives" and are each followed by a push; the
        # third ignore reaches "held_back" -- the point past the last rung
        # this criterion is about -- and is not followed by one (criterion
        # 1741's own throttle). That third ignore is the standalone end_turn
        # below, with no assert_receive after it.
        Enum.each(1..2, fn _ ->
          :ok = Fixtures.put_agent_mid_turn(context.scope, id)
          :ok = Fixtures.end_turn(context.scope, id)
          assert_receive {:work_turn_requested, ^id, _ref, _rung}, 2_000
        end)

        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, context}
      end

      # Product's correction on 3e9a96e9 (itself correcting 1ef7cfe3): "stays
      # open, as escalated" describes the offer record, not a further wake.
      # Pushes stop past the last rung exactly as they do for a decline --
      # that is criterion 1741's own throttle, built to stop a measured
      # runaway loop (197 turns in 3m29s on the math project, 2026-09-22),
      # and this criterion does not reopen it. What differs from a decline
      # is that the offer itself is never closed: it stays open, and a pull
      # (get_next_requirement) still shows and can act on it.
      then_ "the offer is not withdrawn: it stays open, but is not pushed again", context do
        id = context.coder

        refute_receive {:work_turn_requested, ^id, _ref, _again}, 1_000,
                        "work ignored past its last rung was pushed to the agent again"

        recorded =
          Enum.filter(offers(context, context.coder, %{kind: "work"}), &(&1.subject == context.subject))

        assert [%{status: "open"} | _] = recorded, listing(context)

        {:ok, context}
      end

      then_ "and main is told once, naming the agent, the offer and what it asked", context do
        main_id = context.main_id
        coder = context.coder
        assert_receive {:agent_dispatch, ^main_id, _ref, notice}, 2_000
        assert notice =~ coder, notice
        {:ok, context}
      end
    end
  end
end
