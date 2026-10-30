defmodule CodeMySpecSpex.Story1166.Criterion2502Spex do
  @moduledoc "Story 1166, criterion 2502: daily timing distributions by outcome."

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John sees daily stage medians and p90s by promotion outcome", criterion: 2502 do
    scenario "ten landings and eight ejections appear side by side" do
      given_ "10 promotions landed and 8 were ejected in the last 24 hours", context do
        Fixtures.promotion_timing_history(context.scope,
          landed: 10,
          ejected: 8,
          within: :last_24_hours
        )

        {:ok, context}
      end

      when_ "John looks at promotion timing", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "each reached stage shows a median and p90 for landed promotions", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-outcome-landed'][data-count='10']"
               )

        for stage <- ~w(queue-wait gate-build compiler credo exunit spex asset-build landing) do
          assert has_element?(
                   context.timing_view,
                   "[data-test='promotion-summary-landed-#{stage}'] [data-stat='median'][data-duration-seconds]"
                 )

          assert has_element?(
                   context.timing_view,
                   "[data-test='promotion-summary-landed-#{stage}'] [data-stat='p90'][data-duration-seconds]"
                 )
        end

        {:ok, context}
      end

      then_ "the ejected promotions have separate stage medians and p90s", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-outcome-ejected'][data-count='8']"
               )

        for stage <- ~w(queue-wait gate-build compiler credo exunit spex asset-build) do
          assert has_element?(
                   context.timing_view,
                   "[data-test='promotion-summary-ejected-#{stage}'] [data-stat='median'][data-duration-seconds]"
                 )

          assert has_element?(
                   context.timing_view,
                   "[data-test='promotion-summary-ejected-#{stage}'] [data-stat='p90'][data-duration-seconds]"
                 )
        end

        {:ok, context}
      end
    end
  end
end
