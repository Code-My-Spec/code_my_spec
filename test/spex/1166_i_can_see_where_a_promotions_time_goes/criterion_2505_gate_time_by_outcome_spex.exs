defmodule CodeMySpecSpex.Story1166.Criterion2505Spex do
  @moduledoc "Story 1166, criterion 2505: gate time by promotion outcome."

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John sees overnight gate time lost to ejections beside landings", criterion: 2505 do
    scenario "eight ejections used two hours and ten landings used one hour forty minutes" do
      given_ "8 promotions were ejected after two combined hours of gate time and 10 landed after one hour forty minutes",
             context do
        for _ <- 1..8 do
          Fixtures.ejected_promotion_with_timing(context.scope,
            failed_stage: :exunit,
            gate_build: 900,
            compiler: 0,
            credo: 0,
            exunit: 0
          )
        end

        for _ <- 1..10 do
          Fixtures.landed_promotion_with_timing(context.scope,
            queue_wait: 0,
            gate_build: 600,
            compiler: 0,
            credo: 0,
            exunit: 0,
            spex: 0,
            asset_build: 0,
            landing: 0
          )
        end

        {:ok, context}
      end

      when_ "John looks at the last 24 hours of promotion timing", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "he sees two hours of gate time on ejected promotions beside one hour forty minutes on landed ones",
            context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-window'][data-window='24h']"
               )

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-outcome-ejected'][data-count='8']"
               )

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-outcome-landed'][data-count='10']"
               )

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-gate-time-ejected'][data-duration-seconds='7200']"
               )

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-gate-time-landed'][data-duration-seconds='6000']"
               )

        {:ok, context}
      end
    end
  end
end
