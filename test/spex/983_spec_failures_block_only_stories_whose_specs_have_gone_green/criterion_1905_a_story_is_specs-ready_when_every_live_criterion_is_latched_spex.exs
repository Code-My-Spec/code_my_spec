defmodule CodeMySpecSpex.Story983.Criterion1905Spex do
  @moduledoc """
  Story 983 — Criterion 1905: a story counts as specs-ready when every live
  criterion on it is latched.

  The aggregate criterion. It redefines `specs_ready` as a derived fact
  rather than a flag a single certification sets directly: true only once
  nothing live is left unlatched. A criterion still red is merely advisory
  (criterion 1899), so certifying succeeds with it outstanding — it is the
  aggregate that stays false until a later certifying run catches it up too.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The aggregate is true only once every live criterion is latched",
       criterion: 1905 do
    scenario "one criterion green, one still red, across two certifying runs" do
      given_ "a story with two criteria, only one of them ever gone green", context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)

        response = add_criterion(context, story, "It also works on Tuesdays")
        refute response.isError, inspect(response)

        story = Stories.get_story(context.scope, story.id)
        [second] = Enum.reject(story.criteria, &(&1.description == "It works"))

        {:ok, _} =
          Fixtures.record_problem(context.scope, "spex", %{
            file_path: Fixtures.spec_file_path(story, second),
            message: "Tuesday has not been implemented",
            severity: :error
          })

        {:ok, Map.merge(context, %{story: story, second: second})}
      end

      when_ "the story is certified ready for QA the first time", context do
        context = a_held_ready_for_qa_task(context, context.story)
        {:ok, Map.put(context, :first_answer, complete_ready_for_qa(context))}
      end

      then_ "certifying succeeds even with the second criterion still red", context do
        {error?, text} = context.first_answer
        refute error?, text
        {:ok, context}
      end

      then_ "the story does not count as specs-ready yet", context do
        refute satisfied?(story_requirements(context, context.story), "ready_for_qa"),
               "the aggregate must stay false while a live criterion is unlatched"

        {:ok, context}
      end

      when_ "the second criterion goes green and the story is certified again", context do
        :ok =
          write(
            context.agent_root,
            Fixtures.spec_file_path(context.story, context.second),
            passing_spex(context.second)
          )

        context = context |> analyzers_are_current() |> a_held_ready_for_qa_task(context.story)
        {:ok, Map.put(context, :second_answer, complete_ready_for_qa(context))}
      end

      then_ "the story now counts as specs-ready", context do
        {error?, text} = context.second_answer
        refute error?, text
        assert satisfied?(story_requirements(context, context.story), "ready_for_qa")
        {:ok, context}
      end
    end
  end

  defp passing_spex(criterion) do
    """
    defmodule CodeMySpecSpex.Story983.CaughtUpCriterion#{criterion.id}Spex do
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
