defmodule CodeMySpecSpex.Story1166.Criterion2559Spex do
  @moduledoc "Story 1166, criterion 2559: the date slider narrows both promotion charts."

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.AgentPerformanceHelpers
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Moving the slider narrows both charts to the chosen days", criterion: 2559 do
    scenario "the same selected days apply to daily medians and individual promotions" do
      given_ "promotions landed on different days in the last week", context do
        for age_days <- [6, 3, 0] do
          Fixtures.landed_promotion_with_timing(context.scope,
            landed_at: DateTime.add(DateTime.utc_now(), -age_days * 86_400, :second),
            queue_wait: 60,
            gate_build: 60,
            compiler: 60,
            credo: 60,
            exunit: 60,
            spex: 60,
            landing: 60
          )
        end

        {:ok, context}
      end

      when_ "John selects only the most recent day with the chart slider", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")
        view |> element("[data-test='promotion-window-7d']") |> render_click()

        daily_before = AgentPerformanceHelpers.chart_data(view, "[data-test='promotion-daily-stage-chart']")
        entries_before = AgentPerformanceHelpers.chart_data(view, "[data-test='promotion-per-entry-chart']")
        assert length(daily_before["xAxis"]["data"]) == 3
        assert length(entries_before["xAxis"]["data"]) == 3

        view |> element("[data-test='promotion-daily-stage-chart']")
        |> render_hook("promotion-zoom", %{"start" => 90, "end" => 100})

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "both chart sliders show the same narrowed date range", context do
        daily = AgentPerformanceHelpers.chart_data(context.timing_view, "[data-test='promotion-daily-stage-chart']")
        entries = AgentPerformanceHelpers.chart_data(context.timing_view, "[data-test='promotion-per-entry-chart']")

        for chart <- [daily, entries] do
          zoom = List.wrap(chart["dataZoom"])
          assert Enum.any?(zoom, &(&1["type"] == "slider"))
          assert Enum.any?(zoom, &(&1["start"] == 90 and &1["end"] == 100))
        end

        {:ok, context}
      end
    end
  end
end
