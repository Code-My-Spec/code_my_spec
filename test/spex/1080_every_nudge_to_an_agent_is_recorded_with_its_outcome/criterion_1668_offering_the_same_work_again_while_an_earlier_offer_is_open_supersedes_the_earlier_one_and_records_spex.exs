defmodule CodeMySpecSpex.Story1080.Criterion1668Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1668 — Offering the same work again while an earlier offer is open
  supersedes the earlier one and records the new one as the next attempt.

  The agent never took the turn it was offered, so that offer has no outcome
  yet. Offering the same work again replaces it rather than leaving two open
  offers for one piece of work.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "A repeat offer supersedes the open one", criterion: 1668 do
    scenario "the agent never takes its offered turn, and the offer is made again" do
      given_ "coding work is waiting", context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = HarnessHooks.ensure_live_harness(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        {:ok, context}
      end

      given_ "a continuous coder was offered it and has not taken the turn", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = context |> start_session() |> put_to_work()
        id = coder.id
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        {:ok, Map.put(context, :coder, id)}
      end

      given_ "five minutes pass without it starting that turn", context do
        :ok = Fixtures.age_work_reservation(context.scope, context.coder, 301)
        {:ok, context}
      end

      when_ "the copy's work is looked at again", context do
        context = put_to_work(context)
        id = context.coder

        assert_receive {:work_turn_requested, ^id, _ref, _prompt},
                       2_000,
                       "the lapsed offer was not made again"

        {:ok, context}
      end

      then_ "the first offer is superseded and the second is open as attempt 2", context do
        # Newest first.
        assert [second, first] = offers(context, context.coder, %{kind: "work"}),
               "expected two work offers:\n" <> listing(context)

        assert first.subject == second.subject, "the two offers are not for the same work"
        assert {first.status, first.attempt} == {"superseded", 1}
        assert {second.status, second.attempt} == {"open", 2}
        {:ok, context}
      end
    end
  end
end
