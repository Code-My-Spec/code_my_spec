defmodule CodeMySpecSpex.Story1016.Criterion1602Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1602 — Story work is refused on the main copy

  The team on a working copy (its coding and QA agents) works one story
  together and moves on together; the main copy is promoted to, never worked
  on (a31f1cd6 step 3, John 2026-10-01).
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Story work is refused on the main copy", criterion: 1602 do
    scenario "Story work is refused on the main copy" do
      given_ "a main checkout with the main agent on it", context do
        context = Slice.main_copy(context)
        {:ok, CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)}
      end

      when_ "the main agent selects a story for its own copy", context do
        {error?, text} =
          Slice.attempt(
            %{context | scope: context.main_scope},
            SetActiveStory,
            %{story_number: context.story.number},
            %{agent_id: context.main.id}
          )

        {:ok, Map.merge(context, %{error?: error?, text: text})}
      end

      then_ "it is refused: the main copy is promoted to, not worked on", context do
        assert context.error?, "story work was put on the main copy. Got:\n#{context.text}"
        assert context.text =~ "feature copies"
        {:ok, context}
      end

      then_ "and the main agent holds no story", context do
        answer = Slice.next(%{context | scope: context.main_scope}, %{agent_id: context.main.id})
        refute answer =~ "# Story #{context.story.number}:"
        {:ok, context}
      end
    end
  end
end
