defmodule CodeMySpecSpex.Story1016.Criterion1598Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1598 — Switching the team's story releases the old reservation

  The team on a working copy (its coding and QA agents) works one story
  together and moves on together; the main copy is promoted to, never worked
  on (a31f1cd6 step 3, John 2026-10-01).
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Switching the team's story releases the old reservation", criterion: 1598 do
    scenario "Switching the team's story releases the old reservation" do
      given_ "a team on story A, a story B, and a second feature copy with its own team",
             context do
        context = context |> Slice.main_copy() |> Slice.base() |> Slice.waiting()
        other_scope = CodeMySpecSpex.Fixtures.live_agent_scope(context.scope)
        other = Slice.staff(%{context | scope: other_scope})
        {:ok, Map.put(context, :other, other)}
      end

      when_ "the team switches to story B", context do
        Slice.call(context, "set_active_story", %{story_number: context.waiting.number})
        {:ok, context}
      end

      then_ "story A is free for the other copy's team to take", context do
        {error?, text} =
          Slice.attempt(context.other, "set_active_story", %{story_number: context.story.number})

        refute error?, "the story the team moved off is still held by its old copy. Got:\n#{text}"
        [agent | _] = context.other.team

        assert Slice.next(context.other, %{agent_id: agent.id}) =~
                 "# Story #{context.story.number}:"

        {:ok, context}
      end
    end
  end
end
