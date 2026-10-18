defmodule CodeMySpecSpex.Story561.Criterion3610Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3610 — The working copy waits for an answer on its active story
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The working copy waits for an answer on its active story", criterion: 1508 do
    scenario "The working copy waits for an answer on its active story" do
      given_ "an unanswered question standing against the active story", context do
        context = context |> Slice.base() |> Slice.child() |> Slice.waiting()
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        response =
          Slice.call(context, "add_question", %{
            story_number: context.story.number,
            text: "Must a booking have a customer?"
          })

        [question_id | _] =
          Regex.run(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, response)

        blocked = Slice.next(context)
        Slice.assert_active(blocked, context, "blocked")
        assert blocked =~ "Must a booking have a customer?"
        refute blocked =~ "requirement_name=`"

        Slice.call(context, "resolve_question", %{
          question_id: question_id,
          resolution: "Yes, every booking needs a customer"
        })

        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the answer names the question that is holding the story", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        {:ok, context}
      end
    end
  end
end
