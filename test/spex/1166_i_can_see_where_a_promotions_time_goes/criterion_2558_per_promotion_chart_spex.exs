defmodule CodeMySpecSpex.Story1166.Criterion2558Spex do
  @moduledoc "Story 1166, criterion 2558: one stacked bar per promotion, grouped by outcome."

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.AgentPerformanceHelpers
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John compares the stages of individual landed and ejected promotions", criterion: 2558 do
    scenario "each promotion has a stacked bar and the two outcomes are apart" do
      given_ "ten promotions landed and eight were ejected in the last day", context do
        Fixtures.promotion_timing_history(context.scope, landed: 10, ejected: 8)
        {:ok, context}
      end

      when_ "John opens promotion timing", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")
        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "the chart has a stage stack for every promotion and separates landed from ejected", context do
        chart = AgentPerformanceHelpers.chart_data(context.timing_view, "[data-test='promotion-per-entry-chart']")
        categories = chart["xAxis"]["data"]

        assert length(categories) == 18
        assert Enum.count(categories, &String.starts_with?(&1, "Landed")) == 10
        assert Enum.count(categories, &String.starts_with?(&1, "Ejected")) == 8

        for stage <- ~w(queue-wait gate-build compiler credo exunit spex landing) do
          series = Enum.find(chart["series"], &(&1["name"] == stage))
          assert series, "missing #{stage} from the per-promotion chart"
          assert series["type"] == "bar"
          assert series["stack"] == "promotion-time"
          assert length(series["data"]) == 18
        end

        {:ok, context}
      end
    end
  end
end
