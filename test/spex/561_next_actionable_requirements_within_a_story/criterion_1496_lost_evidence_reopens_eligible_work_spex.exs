defmodule CodeMySpecSpex.Story561.Criterion3598Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3598 — Lost evidence reopens eligible work
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Lost evidence reopens eligible work", criterion: 1496 do
    scenario "Lost evidence reopens eligible work" do
      given_ "a requirement whose evidence has been deleted", context do
        context = Slice.base(context)
        context = Slice.topology(context, [{"Reservations.Booking", :schema, []}])

        refute Slice.offered?(
                 Slice.next(context),
                 Slice.component(context, "Reservations.Booking").id
               )

        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        context = Slice.missing(context, "Reservations.Booking")
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the work it satisfied is offered again", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        {:ok, context}
      end
    end
  end
end
