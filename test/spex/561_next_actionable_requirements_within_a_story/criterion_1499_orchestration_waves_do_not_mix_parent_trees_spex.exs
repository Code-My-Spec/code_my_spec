defmodule CodeMySpecSpex.Story561.Criterion3601Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3601 — Orchestration waves do not mix parent trees
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Orchestration waves do not mix parent trees", criterion: 1499 do
    scenario "Orchestration waves do not mix parent trees" do
      given_ "actionable work sitting under two different parents", context do
        context = Slice.base(context)

        context =
          Slice.topology(context, [
            {"Reservations", :context, ["Catalog", "Stock"]},
            {"Catalog", :context, []},
            {"Catalog.Item", :schema, []},
            {"Catalog.Price", :schema, []},
            {"Stock", :context, []},
            {"Stock.Item", :schema, []}
          ])

        context =
          context
          |> Slice.missing("Catalog.Item")
          |> Slice.missing("Catalog.Price")
          |> Slice.missing("Stock.Item")

        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the wave holds one parent's work rather than mixing the trees", context do
        Slice.assert_active(context.answer, context, "ready")
        assert context.answer =~ "Wave: 2 requirement"
        assert context.answer =~ "Remaining: 1"
        assert Slice.offered?(context.answer, Slice.component(context, "Catalog.Item").id)
        assert Slice.offered?(context.answer, Slice.component(context, "Catalog.Price").id)
        refute Slice.offered?(context.answer, Slice.component(context, "Stock.Item").id)
        {:ok, context}
      end
    end
  end
end
