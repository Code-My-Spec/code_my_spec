defmodule CodeMySpecSpex.Story1016.Criterion2061Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 2061 — The team moves to its next story when its current story has
  landed.

  A team on a working copy works one story together and moves on together. For
  the move, "landed" means finished *and* promoted: John, 2026-10-06 (issue
  f0c18598), a team's active story stays until it lands, and the epic pull may
  only bind the team to the next story once that has happened — never because
  the story merely reads certified or complete before QA. So the scenario
  completes and lands the story (`Slice.land/1`) before asking what comes next,
  and then asserts the whole team — coding and QA alike — is on the next story.

  This restates criterion 1600's behaviour for the same story; see the issue
  filed against this story for the duplication.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The team moves to its next story when its current story has landed",
       criterion: 2061 do
    scenario "the team's current story has landed and another story is ready" do
      given_ "a team whose story has landed, and another story waiting", context do
        context = context |> Slice.staff() |> Slice.complete() |> Slice.waiting()
        context = Slice.land(context)
        {:ok, context}
      end

      when_ "the coding agent asks what to work on", context do
        [coding, qa] = context.team
        answer = Slice.next(context, %{agent_id: coding.id})
        {:ok, Map.merge(context, %{answer: answer, qa: qa})}
      end

      then_ "it is on the next story", context do
        assert context.answer =~ "# Story #{context.waiting.number}:",
               "the team stayed on its landed story instead of moving on. Got:\n#{context.answer}"

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
