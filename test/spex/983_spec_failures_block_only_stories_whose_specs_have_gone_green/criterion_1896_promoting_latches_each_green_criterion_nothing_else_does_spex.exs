defmodule CodeMySpecSpex.Story983.Criterion1896Spex do
  @moduledoc """
  Story 983 — Criterion 1896: promoting latches each of the story's criteria
  whose spex is green on the certifying run; nothing else sets a criterion's
  latch.

  The counterpart to criterion 1895: a green run sitting beside a promotion
  earns nothing on its own. Promoting is what sets the latch, and it sets it
  only on the criteria it certified green — a sibling that stayed red (merely
  advisory while unlatched, criterion 1899) is promoted right along with it
  but comes out the other side exactly as unlatched as it went in.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Only promoting latches a criterion, and only the ones it certifies green",
       criterion: 1896 do
    scenario "one criterion green, one newly added and red, at promotion" do
      given_ "a promotable story with a second, still-red criterion", context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)

        response = add_criterion(context, story, "It also works on Tuesdays")
        refute response.isError, inspect(response)

        story = Stories.get_story(context.scope, story.id)
        [green] = Enum.filter(story.criteria, &(&1.description == "It works"))
        [red] = Enum.reject(story.criteria, &(&1.description == "It works"))

        {:ok, _} =
          Fixtures.record_problem(context.scope, "spex", %{
            file_path: Fixtures.spec_file_path(story, red),
            message: "Tuesday has not been implemented",
            severity: :error
          })

        {:ok, Map.merge(context, %{story: story, green: green, red: red})}
      end

      then_ "neither criterion carries a latch before anyone promotes", context do
        assert criterion_latch(context, context.green) == nil
        assert criterion_latch(context, context.red) == nil
        {:ok, context}
      end

      when_ "the story is promoted despite the red, unlatched criterion", context do
        response = promote(context, context.story.number)
        {:ok, Map.put(context, :promote_response, response)}
      end

      then_ "the promotion succeeds", context do
        refute context.promote_response.isError, inspect(context.promote_response)
        {:ok, context}
      end

      then_ "the green criterion is latched and the red one is still not", context do
        assert criterion_latch(context, context.green) != nil,
               "promoting must latch the criterion whose spex was green on the certifying run"

        assert criterion_latch(context, context.red) == nil,
               "a criterion promotion did not certify green must not come out latched"

        {:ok, context}
      end
    end
  end
end
