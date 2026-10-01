defmodule CodeMySpecSpex.Story1016.Criterion1600Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1600 — The team moves to its next story when the whole story is complete

  The team on a working copy (its coding and QA agents) works one story
  together and moves on together; the main copy is promoted to, never worked
  on (a31f1cd6 step 3, John 2026-10-01).
  """
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The team moves to its next story when the whole story is complete", criterion: 1600 do
    scenario "The team moves to its next story when the whole story is complete" do
      given_ "a team whose story is complete, and another story ready for development", context do
        context = context |> Slice.staff() |> Slice.complete() |> Slice.waiting()
        {:ok, context}
      end

      when_ "the coding agent asks what to work on", context do
        [coding, qa] = context.team
        answer = Slice.next(context, %{agent_id: coding.id})
        {:ok, Map.merge(context, %{answer: answer, qa: qa})}
      end

      then_ "it is on the next story", context do
        assert context.answer =~ "# Story #{context.waiting.number}:",
               "a team whose story is finished waited for someone to move it. Got:\n#{context.answer}"

        {:ok, context}
      end

      then_ "and so is the rest of the team", context do
        assert Slice.next(context, %{agent_id: context.qa.id}) =~
                 "# Story #{context.waiting.number}:"

        {:ok, context}
      end
    end
  end
end
