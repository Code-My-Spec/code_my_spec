defmodule CodeMySpecSpex.Story1166.Criterion2506Spex do
  @moduledoc "Story 1166, criterion 2506: unrelated agent analysis is excluded from promotion timing."

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John's promotion figures exclude a partial agent ExUnit run", criterion: 2506 do
    scenario "a three minute agent run does not change the promotion ExUnit median or p90" do
      given_ "three promotions landed in the last 24 hours with ExUnit times of 60, 60, and 120 seconds", context do
        for duration <- [60, 60, 120] do
          Fixtures.landed_promotion_with_timing(context.scope,
            queue_wait: 0,
            gate_build: 0,
            compiler: 0,
            credo: 0,
            exunit: duration,
            spex: 0,
            asset_build: 0,
            landing: 0
          )
        end

        {:ok, context}
      end

      given_ "an agent also requested a partial ExUnit run lasting three minutes while no promotion was running", context do
        Fixtures.partial_agent_analysis_run(context.scope,
          source: :exunit,
          duration_seconds: 180,
          started_at: DateTime.add(DateTime.utc_now(), -1800, :second)
        )

        {:ok, context}
      end

      when_ "John looks at the last 24 hours of promotion timing", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")
        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "the promotion ExUnit median remains 60 seconds and p90 remains 120 seconds", context do
        assert has_element?(context.timing_view, "[data-test='promotion-window'][data-window='24h']")
        assert has_element?(context.timing_view, "[data-test='promotion-outcome-landed'][data-count='3']")
        assert has_element?(context.timing_view, "[data-test='promotion-summary-landed-exunit'] [data-stat='median'][data-duration-seconds='60']")
        assert has_element?(context.timing_view, "[data-test='promotion-summary-landed-exunit'] [data-stat='p90'][data-duration-seconds='120']")
        {:ok, context}
      end
    end
  end
end
