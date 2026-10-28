defmodule CodeMySpecSpex.Story1166.Criterion2547Spex do
  @moduledoc "Story 1166, criterion 2547: the displayed spex median matches its gate runs."

  use CodeMySpecSpex.Case

  alias CodeMySpec.PromotionQueue.Timings
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "the landed spex median agrees with recorded gate runs", criterion: 2547 do
    scenario "three landed promotions have a median spex run of 20 seconds" do
      given_ "landed promotions have distinct spex run durations", context do
        for seconds <- [10, 20, 40] do
          Fixtures.landed_promotion_with_timing(context.scope, spex: seconds)
        end

        {:ok, context}
      end

      when_ "John reads the last day's timing and the associated run ledger", context do
        figures = Timings.summary(context.project.id, "24h")

        observed = Fixtures.promotion_spex_run_seconds(context.scope)
        {:ok, Map.merge(context, %{figures: figures, observed: observed})}
      end

      then_ "the displayed spex median equals the median of those recorded runs", context do
        observed = context.observed
        assert observed == [10, 20, 40]

        assert get_in(context.figures, ["outcomes", "landed", "stages", "spex", "median_seconds"]) ==
                 Enum.at(observed, 1)

        {:ok, context}
      end
    end
  end
end
