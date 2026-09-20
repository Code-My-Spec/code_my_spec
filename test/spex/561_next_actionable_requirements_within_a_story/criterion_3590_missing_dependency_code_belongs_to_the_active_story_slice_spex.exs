defmodule CodeMySpecSpex.Story561.Criterion3590Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3590 — Missing dependency code belongs to the active story slice
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Missing dependency code belongs to the active story slice" do
    scenario "Missing dependency code belongs to the active story slice" do
      given_ "the story's component depends on one that has no implementation", context do
        context = Slice.base(context)

        context =
          Slice.topology(context, [
            {"Reservations", :context, ["Catalog"]},
            {"Catalog", :context, ["Stock"]},
            {"Stock", :context, []},
            {"Stock.Item", :schema, []}
          ])

        context = context |> Slice.missing("Stock.Item") |> Slice.missing("Stock")
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the dependency's implementation is offered as part of this story", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Stock.Item").id)
        refute Slice.offered?(context.answer, Slice.component(context, "Stock").id)
        {:ok, context}
      end
    end
  end
end
