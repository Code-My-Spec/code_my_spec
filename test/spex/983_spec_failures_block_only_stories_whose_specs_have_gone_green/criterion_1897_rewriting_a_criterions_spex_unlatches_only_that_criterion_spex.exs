defmodule CodeMySpecSpex.Story983.Criterion1897Spex do
  @moduledoc """
  Story 983 — Criterion 1897: rewriting a criterion's spex unlatches that
  criterion only.

  The per-criterion counterpart to criterion 733 (rewriting a story's BDD
  specs restarts the whole story's chain). With the latch living on the
  criterion rather than the story, a rewrite only has to restart the one
  contract that changed — a sibling criterion's own green run says nothing
  about it and is left alone.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A rewrite unlatches only the criterion whose spex changed", criterion: 1897 do
    scenario "two latched criteria, one of them rewritten" do
      given_ "a story with two criteria, both latched by a certifying promotion",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)

        response = add_criterion(context, story, "It also works on Tuesdays")
        refute response.isError, inspect(response)

        story = Stories.get_story(context.scope, story.id)
        [first] = Enum.filter(story.criteria, &(&1.description == "It works"))
        [second] = Enum.reject(story.criteria, &(&1.description == "It works"))

        second_path = Fixtures.spec_file_path(story, second)

        :ok = write(context.agent_root, second_path, passing_spex(second))
        :ok = Environments.write_file(context.environment, second_path, passing_spex(second))
        {:ok, _} = FileSync.sync_changed(context.scope)

        context = analyzers_are_current(context)

        response = promote(context, story.number)
        refute response.isError, inspect(response)

        {:ok, Map.merge(context, %{story: story, first: first, second: second})}
      end

      then_ "both criteria are latched before the rewrite", context do
        assert criterion_latch(context, context.first) != nil
        assert criterion_latch(context, context.second) != nil
        {:ok, context}
      end

      when_ "the second criterion's own spex file is rewritten", context do
        path = Fixtures.spec_file_path(context.story, context.second)
        :ok = write(context.agent_root, path, rewritten_spex(context.second))
        :ok = Environments.write_file(context.environment, path, rewritten_spex(context.second))
        {:ok, _} = FileSync.sync_changed(context.scope)
        context = analyzers_are_current(context)
        {:ok, context}
      end

      then_ "only the rewritten criterion lost its latch", context do
        assert criterion_latch(context, context.first) != nil,
               "a sibling's own spex changing must not touch this criterion's latch"

        assert criterion_latch(context, context.second) == nil,
               "rewriting a criterion's own spex must unlatch that criterion"

        {:ok, context}
      end
    end
  end

  defp passing_spex(criterion) do
    """
    defmodule CodeMySpecSpex.Story983.SecondCriterion#{criterion.id}Spex do
      use CodeMySpecSpex.Case

      spex \"it also works on Tuesdays\", criterion: #{criterion.number} do
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

  defp rewritten_spex(criterion) do
    """
    defmodule CodeMySpecSpex.Story983.SecondCriterion#{criterion.id}Spex do
      use CodeMySpecSpex.Case

      spex \"it also works on Tuesdays, under a revised contract\", criterion: #{criterion.number} do
        scenario \"the revised rule holds\" do
          then_ \"it succeeds under the new expectation\" do
            assert 2 == 2
            :ok
          end
        end
      end
    end
    """
  end
end
