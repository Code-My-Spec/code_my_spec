defmodule CodeMySpecSpex.Story983.Criterion1903Spex do
  @moduledoc """
  Story 983 — Criterion 1903: changing a story's readiness or parking it
  never changes any criterion's latch.

  The per-criterion counterpart to criterion 740 (parking by hand). 740
  shows parking stops failing specs from blocking; this shows the latch
  itself — the fact a criterion once went green on a certifying run — is
  untouched by either flag, because both are about enforcement, not about
  what has or has not been certified.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias CodeMySpec.Stories

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Readiness and parking leave every criterion's latch alone", criterion: 1903 do
    scenario "a certified story is parked and un-readied" do
      given_ "a story certified ready for QA, its one criterion latched", context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)
        context = a_held_ready_for_qa_task(context, story)
        {false, _} = complete_ready_for_qa(context)
        story = Stories.get_story(context.scope, story.id)
        [criterion] = story.criteria
        {:ok, Map.merge(context, %{story: story, criterion: criterion})}
      end

      then_ "the criterion is latched before anything changes", context do
        assert criterion_latch(context, context.criterion) != nil
        {:ok, context}
      end

      when_ "the story is parked and marked not ready for development", context do
        story = Stories.get_story!(context.scope, context.story.id)
        {:ok, _} = Stories.set_specs_ready(context.scope, story, false)
        {:ok, _} = Stories.update_story(context.scope, story, %{ready_for_dev: false})
        {:ok, context}
      end

      then_ "the criterion's latch is unchanged", context do
        assert criterion_latch(context, context.criterion) != nil,
               "parking a story or changing its readiness must not touch a criterion's latch"

        {:ok, context}
      end
    end
  end
end
