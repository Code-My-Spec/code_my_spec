defmodule CodeMySpecSpex.Story561.Criterion3596Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3596 — Another checkout cannot satisfy local implementation work
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Another checkout cannot satisfy local implementation work" do
    scenario "Another checkout cannot satisfy local implementation work" do
      given_ "the implementation present in another checkout but not this one", context do
        context = context |> Slice.base() |> Slice.child()
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        other = CodeMySpecSpex.Fixtures.live_agent_scope(context.scope)

        :ok =
          CodeMySpec.Environments.write_file(
            other.environment,
            "lib/reservations/booking.ex",
            "defmodule Reservations.Booking do end"
          )

        CodeMySpecSpex.Fixtures.observe_files_as(other, other.active_working_copy_id, [
          "lib/reservations/booking.ex"
        ])

        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the work is still offered here, because presence is per checkout", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        {:ok, context}
      end
    end
  end
end
