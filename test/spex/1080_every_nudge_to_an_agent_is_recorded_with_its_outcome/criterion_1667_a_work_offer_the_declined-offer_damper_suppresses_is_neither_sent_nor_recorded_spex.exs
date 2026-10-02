defmodule CodeMySpecSpex.Story1080.Criterion1667Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1667 — A work offer the declined-offer damper suppresses is neither
  sent nor recorded.

  An agent that ends turn after turn without taking the work it was offered is
  damped after five: the same offer is not made again for a while. A damped
  offer is not an offer, so there is nothing to record.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "A damped offer is not recorded", criterion: 1667 do
    scenario "a coder ignores the same work five turns running" do
      given_ "coding work is waiting", context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        {:ok, context}
      end

      given_ "a continuous coder was offered it and ended five turns without taking it",
             context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = context |> start_session() |> put_to_work()
        id = coder.id
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000

        for turn <- 1..4 do
          :ok = Fixtures.put_agent_mid_turn(context.scope, id)
          :ok = Fixtures.end_turn(context.scope, id)

          assert_receive {:work_turn_requested, ^id, _ref, _prompt},
                         2_000,
                         "turn #{turn} ended without the next offer being made"
        end

        {:ok, Map.put(context, :coder, id)}
      end

      when_ "it ends a fifth turn without taking the work", context do
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "no sixth offer is sent", context do
        id = context.coder
        refute_receive {:work_turn_requested, ^id, _ref, _prompt}, 500
        {:ok, context}
      end

      then_ "and none is recorded: the five that were made are all it has", context do
        work = offers(context, context.coder, %{kind: "work"})

        assert length(work) == 5,
               "expected the five offers made and no sixth:\n" <> listing(context)

        assert Enum.all?(work, &(&1.status == "ignored")),
               "every offer it ended a turn on without taking should be ignored:\n" <>
                 listing(context)

        {:ok, context}
      end
    end
  end
end
