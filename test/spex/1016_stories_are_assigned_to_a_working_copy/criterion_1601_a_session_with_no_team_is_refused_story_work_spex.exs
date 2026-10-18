defmodule CodeMySpecSpex.Story1016.Criterion1601Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1601 — A session with no team is refused story work

  The team on a working copy (its coding and QA agents) works one story
  together and moves on together; the main copy is promoted to, never worked
  on (a31f1cd6 step 3, John 2026-10-01).
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A session with no team is refused story work", criterion: 1601 do
    scenario "A session with no team is refused story work" do
      given_ "a working copy with no coding or QA agent, and a story ready for development",
             context do
        {:ok, CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)}
      end

      when_ "a session selects the story", context do
        {error?, text} =
          Slice.attempt(context, "set_active_story", %{story_number: context.story.number})

        {:ok, Map.merge(context, %{error?: error?, text: text})}
      end

      then_ "it is refused because nobody on the copy can work it", context do
        assert context.error?,
               "a story was handed to a copy with nobody to work it. Got:\n#{context.text}"

        assert context.text =~ "No coding or QA agent"
        {:ok, context}
      end
    end
  end
end
