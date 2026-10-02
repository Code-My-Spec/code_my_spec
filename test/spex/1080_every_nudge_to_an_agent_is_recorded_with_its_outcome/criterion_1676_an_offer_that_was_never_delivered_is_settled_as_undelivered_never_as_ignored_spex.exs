defmodule CodeMySpecSpex.Story1080.Criterion1676Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1676 — An offer that was never delivered is settled as
  undelivered, never as ignored.

  Ignored means the agent saw the offer and did not act on it. An offer whose
  machine could not be reached was never seen, and counting it as ignored
  would charge the agent for an outage.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [machine_out_of_reach: 0]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An offer that never arrived is undelivered", criterion: 1676 do
    scenario "work is offered to a coder whose machine cannot be reached" do
      given_ "coding work is waiting and the coder's machine is out of reach", context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        :ok = machine_out_of_reach()
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        {:ok, context |> start_session() |> Map.put(:coder, coder.id)}
      end

      when_ "the copy is switched on, offering it the work", context do
        context = put_to_work(context)

        eventually(fn ->
          assert [_ | _] = offers(context, context.coder, %{kind: "work"}),
                 "no work offer was made:\n" <> listing(context)
        end)

        {:ok, context}
      end

      then_ "the offer is undelivered", context do
        assert Enum.all?(
                 offers(context, context.coder, %{kind: "work"}),
                 &(&1.status == "undelivered")
               ),
               listing(context)

        {:ok, context}
      end

      when_ "a turn end arrives afterwards", context do
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "it is still undelivered, not ignored", context do
        work = offers(context, context.coder, %{kind: "work"})
        refute Enum.any?(work, &(&1.status == "ignored")), listing(context)
        assert List.last(work).status == "undelivered", listing(context)
        {:ok, context}
      end
    end
  end
end
