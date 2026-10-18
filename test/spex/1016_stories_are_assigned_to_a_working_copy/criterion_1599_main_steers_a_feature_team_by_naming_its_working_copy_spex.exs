defmodule CodeMySpecSpex.Story1016.Criterion1599Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1599 — Main steers a feature team by naming its working copy

  The team on a working copy (its coding and QA agents) works one story
  together and moves on together; the main copy is promoted to, never worked
  on (a31f1cd6 step 3, John 2026-10-01).
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main steers a feature team by naming its working copy", criterion: 1599 do
    scenario "Main steers a feature team by naming its working copy" do
      given_ "a main checkout with the main agent, and a feature copy with a team", context do
        context = context |> Slice.main_copy() |> Slice.staff()
        {:ok, CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)}
      end

      when_ "the main agent selects a story for the feature copy", context do
        text =
          Slice.call(
            %{context | scope: context.main_scope},
            "set_active_story",
            %{
              story_number: context.story.number,
              working_copy_id: context.scope.active_working_copy_id
            },
            %{agent_id: context.main.id}
          )

        {:ok, Map.put(context, :text, text)}
      end

      then_ "the feature copy's team is on that story", context do
        for agent <- context.team do
          assert Slice.next(context, %{agent_id: agent.id}) =~ "# Story #{context.story.number}:"
        end

        {:ok, context}
      end

      then_ "and the main agent holds no story itself", context do
        answer = Slice.next(%{context | scope: context.main_scope}, %{agent_id: context.main.id})
        refute answer =~ "# Story #{context.story.number}:"
        {:ok, context}
      end
    end
  end
end
