defmodule CodeMySpecSpex.Story983.Criterion1902Spex do
  @moduledoc """
  Story 983 — Criterion 1902: the ready-for-QA stamp clears when the story's
  spex are rewritten, a criterion is added or retired, or it is unmarked.

  The sibling file at the old number for this rule already covers the
  "added" case. This file exercises "retired" instead, so the two do not
  just repeat each other under a renumbering. "Rewritten" is criterion
  1897's own assertion (it unlatches the rewritten criterion, which 1905
  then means clears the aggregate too); "unmarked" is criterion 740's.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retiring a criterion clears a certified story's stamp", criterion: 1902 do
    scenario "product retires a criterion after certification" do
      given_ "a story with two criteria, certified ready for QA through its held task",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)

        response = add_criterion(context, story, "It also works on Tuesdays")
        refute response.isError, inspect(response)

        story = Stories.get_story(context.scope, story.id)
        [second] = Enum.reject(story.criteria, &(&1.description == "It works"))

        :ok =
          write(
            context.agent_root,
            Fixtures.spec_file_path(story, second),
            passing_spex(second)
          )

        context = context |> analyzers_are_current() |> a_held_ready_for_qa_task(story)
        {false, _} = complete_ready_for_qa(context)

        {:ok, Map.merge(context, %{story: story, second: second})}
      end

      when_ "the second criterion is retired", context do
        response = retire_criterion(context, context.second)
        refute response.isError, inspect(response)
        {:ok, context}
      end

      then_ "the stamp is gone and the story is no longer ready for QA", context do
        assert qa_stamp(context, context.story) == nil
        refute satisfied?(story_requirements(context, context.story), "ready_for_qa")
        {:ok, context}
      end
    end
  end

  defp passing_spex(criterion) do
    """
    defmodule CodeMySpecSpex.Story983.RetiredCriterion#{criterion.id}Spex do
      use CodeMySpecSpex.Case

      spex \"it also works on Tuesdays\", criterion: #{criterion.id} do
        scenario \"the criterion holds\" do
          then_ \"it succeeds\" do
            assert 1 == 1
            :ok
          end
        end
      end
    end
    """
  end
end
