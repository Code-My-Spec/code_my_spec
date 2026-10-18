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
        {:ok, Map.merge(context, %{coder: id, main_id: main.id})}
      end

      when_ "it ignores every rung of that offer", context do
        id = context.coder

        Enum.each(1..3, fn _ ->
          :ok = Fixtures.put_agent_mid_turn(context.scope, id)
          :ok = Fixtures.end_turn(context.scope, id)
          assert_receive {:work_turn_requested, ^id, _ref, _rung}, 2_000
        end)

        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, context}
      end

      then_ "the offer is not withdrawn: it stays open on the agent, as escalated", context do
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, _again}, 2_000
        assert [%{status: "open"} | _] = offers(context, context.coder, %{kind: "work"}),
               listing(context)

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
