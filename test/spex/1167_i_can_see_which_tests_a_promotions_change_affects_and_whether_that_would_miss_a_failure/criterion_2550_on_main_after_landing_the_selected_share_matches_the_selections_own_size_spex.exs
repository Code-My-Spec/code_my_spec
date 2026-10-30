defmodule CodeMySpecSpex.Story1167.Criterion2550Spex do
  @moduledoc "Story 1167, criterion 2550: selected share reconciles with the recorded gate selection."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Promotion.Tools.GetPromotionTimings
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "On main after landing, the selected share matches the selection's own size",
    criterion: 2550 do
    scenario "a landed promotion reports the share calculated from its recorded selection" do
      given_ "story 1167 has landed and a promotion selected 7 of 35 tests on its gate",
             context do
        Fixtures.story_landed_on_main(context.scope, 1167)

        entry =
          Fixtures.landed_promotion_with_gate_selection(context.scope,
            suite_size: 35,
            selected_size: 7,
            failures: []
          )

        {:ok, Map.put(context, :promotion, entry)}
      end

      when_ "Main reads the promotion's timing and recorded gate selection", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetPromotionTimings.execute(%{window: "24h"}, frame)

        refute response.isError
        figures = response |> response_text() |> Jason.decode!()
        selection = Fixtures.promotion_gate_selection(context.scope, context.promotion.id)
        {:ok, Map.merge(context, %{figures: figures, selection: selection})}
      end

      then_ "the displayed share equals the recorded selection divided by the suite size",
            context do
        assert length(context.selection.selected_tests) == 7
        assert context.selection.suite_size == 35

        expected_percent =
          100 * length(context.selection.selected_tests) / context.selection.suite_size

        promotion = Enum.find(context.figures["promotions"], &(&1["id"] == context.promotion.id))
        assert promotion["selected_share_percent"] == expected_percent
        {:ok, context}
      end
    end
  end
end
