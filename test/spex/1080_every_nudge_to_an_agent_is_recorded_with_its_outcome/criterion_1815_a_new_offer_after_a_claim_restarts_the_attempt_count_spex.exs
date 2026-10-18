defmodule CodeMySpecSpex.Story1080.Criterion1815Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1815 — A new offer after a claim restarts the attempt count.

  The attempt counts the tries since the agent last took it, so a claim
  resets it: the next offer for the same work starts again at attempt one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

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
    scenario "a coder claims a work offer, then the same work is offered again later" do
      given_ "coding work is waiting and a continuous coder claims the offer by starting it",
             context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = HarnessHooks.ensure_live_harness(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = context |> start_session() |> put_to_work()
        id = coder.id
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        context = start_agent_task(context, id, next_task(context, id))
        {:ok, Map.put(context, :coder, id)}
      end

      when_ "the same work is offered to it again later", context do
        context = put_to_work(context)
        id = context.coder

        assert_receive {:work_turn_requested, ^id, _ref, _prompt},
                       2_000,
                       "the work was not offered again after the claim"

        {:ok, context}
      end

      then_ "the new offer is recorded as attempt one", context do
        # Newest first: the claim, then the fresh offer that followed it.
        assert [fresh, claimed] = offers(context, context.coder, %{kind: "work"}),
               "expected the claimed offer and a fresh one after it:\n" <> listing(context)

        assert claimed.status == "claimed"
        assert fresh.attempt == 1, "the offer after a claim did not restart at attempt 1"
        {:ok, context}
      end
    end
  end
end
