defmodule CodeMySpecSpex.Story1167.Criterion2515Spex do
  @moduledoc "Story 1167, criterion 2515: daily selection shares and miss count."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Promotion.Tools.GetPromotionTimings
  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John reads that promotions selected a fifth of the suite with no misses over the last day",
    criterion: 2515 do
    scenario "the last day's promotion timing shows each selected share and zero misses" do
      given_ "20 promotions in the last 24 hours each select 20 of 100 tests and have no failing tests",
             context do
        Fixtures.promotion_history_with_gate_selections(context.scope,
          count: 20,
          within: :last_24_hours,
          suite_size: 100,
          selected_size: 20,
          failures: []
        )

        {:ok, context}
      end

      when_ "John opens promotion timing for the last day", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetPromotionTimings.execute(%{project_id: context.project.id, window: "24h"}, frame)

        refute response.isError
        figures = response |> response_text() |> Jason.decode!()

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, context |> Map.put(:tool_figures, figures) |> Map.put(:timing_view, view)}
      end

      then_ "each promotion reports its selected share as 20 percent", context do
        promotions = context.tool_figures["promotions"]
        assert length(promotions) == 20

        for promotion <- promotions do
          assert promotion["selected_share_percent"] == 20

          assert has_element?(
                   context.timing_view,
                   "[data-test='promotion-selected-share'][data-promotion-id='#{promotion["id"]}'][data-percent='20']"
                 )
        end

        {:ok, context}
      end

      then_ "the 24 hour window reports zero misses", context do
        assert context.tool_figures["miss_count"] == 0

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-miss-count'][data-window='24h'][data-count='0']"
               )

        {:ok, context}
      end
    end
  end
end
