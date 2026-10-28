defmodule CodeMySpecSpex.Story1166.Criterion2548Spex do
  @moduledoc "Story 1166, criterion 2548: outcome counts match the queue."

  use CodeMySpecSpex.Case

  alias CodeMySpec.PromotionQueue.Timings
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "landed and ejected counts agree with queue history", criterion: 2548 do
    scenario "a 24 hour window contains three landings and two ejections" do
      given_ "three promotions landed and two were ejected today", context do
        Fixtures.promotion_timing_history(context.scope, landed: 3, ejected: 2)
        {:ok, context}
      end

      when_ "John reads the timing window and the queue ledger", context do
        figures = Timings.summary(context.project.id, "24h")
        counts = Fixtures.promotion_queue_counts(context.scope)
        {:ok, Map.merge(context, %{figures: figures, counts: counts})}
      end

      then_ "both outcome counts match the queue entries in that window", context do
        assert context.counts == %{landed: 3, ejected: 2}

        for outcome <- [:landed, :ejected] do
          expected = Map.fetch!(context.counts, outcome)

          assert get_in(context.figures, ["outcomes", Atom.to_string(outcome), "count"]) ==
                   expected
        end

        {:ok, context}
      end
    end
  end
end
