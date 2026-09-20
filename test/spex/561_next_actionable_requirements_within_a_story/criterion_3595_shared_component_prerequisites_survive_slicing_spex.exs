defmodule CodeMySpecSpex.Story561.Criterion3595Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3595 — Shared component prerequisites survive slicing
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Shared component prerequisites survive slicing" do
    scenario "Shared component prerequisites survive slicing" do
      given_ "a component this story shares with another, still owing work", context do
        context =
          context
          |> Slice.base()
          |> Slice.child()
          |> Slice.waiting(module: "Reservations", bdd: false)

        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the slice still waits on the shared component", context do
        assert context.answer =~ "bdd_specs_exist"
        refute Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        refute context.answer =~ "Status: complete"
        refute Slice.offered?(context.answer, context.waiting.id)
        {:ok, context}
      end
    end
  end
end
