defmodule CodeMySpecSpex.Story1080.Criterion1813Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1813 — An offer that failed to reach the agent settles as
  undelivered, not as ignored.

  Ignored means the agent saw the offer and did not act on it. An offer whose
  machine could not be reached was never seen, and counting it as ignored
  would charge the agent for an outage.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [machine_out_of_reach: 1]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An offer that never arrived settles as undelivered", criterion: 1813 do
    scenario "work is offered to a coder whose machine cannot be reached, then the turn ends" do
      given_ "coding work is waiting and the coder's machine is out of reach", context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = HarnessHooks.ensure_live_harness(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        :ok = machine_out_of_reach(context)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        {:ok, context |> start_session() |> Map.put(:coder, coder.id)}
      end

      when_ "the copy is switched on, offering it the work, and a turn end arrives afterwards",
            context do
        context = put_to_work(context)

        eventually(fn ->
          # A bare match would raise MatchError, which `eventually` does not retry.
          assert offers(context, context.coder, %{kind: "work"}) != [],
                 "no work offer was made:\n" <> listing(context)
        end)

        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the offer settles as undelivered, never as ignored", context do
        work = offers(context, context.coder, %{kind: "work"})
        refute Enum.any?(work, &(&1.status == "ignored")), listing(context)
        assert List.last(work).status == "undelivered", listing(context)
        {:ok, context}
      end
    end
  end
end
