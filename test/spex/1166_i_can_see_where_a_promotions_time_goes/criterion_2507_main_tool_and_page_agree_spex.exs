defmodule CodeMySpecSpex.Story1166.Criterion2507Spex do
  @moduledoc "Story 1166, criterion 2507: Main's tool and John's page agree on promotion timing."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Promotion.Tools.GetPromotionTimings
  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main and John see the same 24 hour promotion timing figures", criterion: 2507 do
    scenario "the tool and page agree on reached stages, medians, p90s, and totals" do
      given_ "landed and ejected promotions ran in the last 24 hours", context do
        Fixtures.promotion_timing_history(context.scope, landed: 10, ejected: 8, within: :last_24_hours)
        {:ok, context}
      end

      when_ "Main asks the promotion timing tool for 24 hours and John opens the same window", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetPromotionTimings.execute(%{project_id: context.project.id, window: "24h"}, frame)

        refute response.isError
        tool_figures = response |> response_text() |> Jason.decode!()
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, context |> Map.put(:tool_figures, tool_figures) |> Map.put(:timing_view, view)}
      end

      then_ "both surfaces report the same window and promotion counts", context do
        assert context.tool_figures["window"] == "24h"
        assert has_element?(context.timing_view, "[data-test='promotion-window'][data-window='24h']")

        for outcome <- ~w(landed ejected) do
          count = get_in(context.tool_figures, ["outcomes", outcome, "count"])
          assert is_integer(count) and count > 0
          assert has_element?(context.timing_view, "[data-test='promotion-outcome-#{outcome}'][data-count='#{count}']")
        end

        {:ok, context}
      end

      then_ "each reached stage has identical median, p90, and total seconds on the tool and page", context do
        for outcome <- ~w(landed ejected) do
          stages = get_in(context.tool_figures, ["outcomes", outcome, "stages"])
          assert is_map(stages) and map_size(stages) > 0

          for {stage, figures} <- stages do
            selector = "[data-test='promotion-summary-#{outcome}-#{stage}']"

            for {stat, key} <- [{"median", "median_seconds"}, {"p90", "p90_seconds"}, {"total", "total_seconds"}] do
              seconds = Map.fetch!(figures, key)
              assert is_number(seconds)
              assert has_element?(context.timing_view, "#{selector} [data-stat='#{stat}'][data-duration-seconds='#{seconds}']")
            end
          end
        end

        {:ok, context}
      end
    end
  end
end
