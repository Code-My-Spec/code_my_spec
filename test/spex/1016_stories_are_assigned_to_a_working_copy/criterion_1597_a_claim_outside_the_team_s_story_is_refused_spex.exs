defmodule CodeMySpecSpex.Story1016.Criterion1597Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1597 — A claim outside the team's story is refused

  The team on a working copy (its coding and QA agents) works one story
  together and moves on together; the main copy is promoted to, never worked
  on (a31f1cd6 step 3, John 2026-10-01).
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A claim outside the team's story is refused", criterion: 1597 do
    scenario "A claim outside the team's story is refused" do
      given_ "a team working one story, and a second story ready for development", context do
        {:ok, context |> Slice.base() |> Slice.waiting()}
      end

      when_ "the coding agent starts work on the second story", context do
        [coding | _] = context.team

        {error?, text} =
          Slice.attempt(
            context,
            "start_task",
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.waiting.number)
            },
            %{agent_id: coding.id}
          )

        {:ok, Map.merge(context, %{error?: error?, text: text, coding: coding})}
      end

      then_ "the claim is refused, naming the story the team is on", context do
        assert context.error?,
               "an agent pulled itself off its team's story. Got:\n#{context.text}"

        assert context.text =~ "team is on story #{context.story.number}"
        {:ok, context}
      end

      then_ "and the agent is still on the team's story", context do
        answer = Slice.next(context, %{agent_id: context.coding.id})
        assert answer =~ "# Story #{context.story.number}:"
        {:ok, context}
      end
    end
  end
end
