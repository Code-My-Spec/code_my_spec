defmodule CodeMySpecSpex.Story983.Criterion1906Spex do
  @moduledoc """
  Story 983 — Criterion 1906: ready-for-QA scopes problems as promotion
  does — the story's own spex must be green; another story's red spex
  counts only where its criterion is latched.

  The cross-story edge of the per-criterion rule, exercised through the
  ready-for-QA gate rather than promotion directly, since the two share one
  procedure (`Promotion.certify/3`). A second story's criterion that has
  never been latched is noise; one that was latched and has since regressed
  is a real, blocking regression — exactly as it would be for the story
  being certified itself.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Another story's red spex blocks certification only where it is latched",
       criterion: 1906 do
    scenario "an unlatched sibling story's red spex does not block" do
      given_ "a promotable story, and a second, never-latched story with a red spec",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context, title: "The story being certified")
        _other = a_promotable_story(context, title: "An unrelated, mid-build story", red?: true)
        context = a_held_ready_for_qa_task(context, story)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the story is certified ready for QA", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "certification succeeds — the unlatched sibling's red spex is advisory", context do
        {error?, text} = context.answer
        refute error?, text
        {:ok, context}
      end
    end
  end

  spex "A latched sibling story's regressed criterion blocks certification",
       criterion: 1906 do
    scenario "a latched sibling story's regressed criterion blocks" do
      given_ "a second story, already certified and latched, whose spec then regresses",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context, title: "The story being certified")
        other = a_promotable_story(context, title: "A previously shipped sibling story")

        other_context = a_held_ready_for_qa_task(context, other)
        {false, _} = complete_ready_for_qa(other_context)

        other = Stories.get_story(context.scope, other.id)
        [other_criterion] = other.criteria

        {:ok, _} =
          Fixtures.record_problem(context.scope, "spex", %{
            file_path: Fixtures.spec_file_path(other, other_criterion),
            message: "the shipped sibling regressed",
            severity: :error
          })

        context = a_held_ready_for_qa_task(context, story)
        {:ok, Map.merge(context, %{story: story, other: other})}
      end

      when_ "the story is certified ready for QA", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "certification is refused, naming the latched sibling's own regression", context do
        {_error?, text} = context.answer
        assert text =~ "spex", text
        {:ok, context}
      end
    end
  end
end
