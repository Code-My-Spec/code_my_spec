defmodule CodeMySpecSpex.Story1166.Criterion2557Spex do
  @moduledoc "Story 1166, criterion 2557: daily median stage times form stacked bars."

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.AgentPerformanceHelpers
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John sees each day's promotion time split by stage", criterion: 2557 do
    scenario "the last week's daily bars stack the median duration of each stage" do
      given_ "promotions ran on two days in the last seven days", context do
        for {age_hours, seconds} <- [{72, 60}, {12, 120}] do
          Fixtures.landed_promotion_with_timing(context.scope,
            landed_at: DateTime.add(DateTime.utc_now(), -age_hours * 3600, :second),
            queue_wait: seconds,
            gate_build: seconds,
            compiler: seconds,
            credo: seconds,
            exunit: seconds,
            spex: seconds,
            landing: seconds
          )
        end

        {:ok, context}
      end

      when_ "John opens promotion timing for the last seven days", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        view |> element("[data-test='promotion-window-7d']") |> render_click()
        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "one bar per day stacks the median of each named stage", context do
        chart =
          AgentPerformanceHelpers.chart_data(
            context.timing_view,
            "[data-test='promotion-daily-stage-chart']"
          )

        assert length(chart["xAxis"]["data"]) == 2

        for stage <- ~w(queue-wait gate-build compiler credo exunit spex landing) do
          series = Enum.find(chart["series"], &(&1["name"] == stage))
          assert series, "missing #{stage} from the daily chart"
          assert series["type"] == "bar"
          assert series["stack"] == "promotion-time"
          assert Enum.sort(series["data"]) == [60, 120]
        end

        {:ok, context}
      end
    end
  end
end
