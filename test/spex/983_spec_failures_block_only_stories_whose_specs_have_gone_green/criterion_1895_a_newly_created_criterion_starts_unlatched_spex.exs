defmodule CodeMySpecSpex.Story983.Criterion1895Spex do
  @moduledoc """
  Story 983 — Criterion 1895: a newly created criterion starts unlatched.

  The sibling it never inherited from already earned its own latch by
  certifying once. If the new criterion started latched too — by riding
  the story's existing stamp — a second certification with only the new
  criterion's own spex red would succeed anyway. It must not: the new
  criterion has never had a green run of its own, so it has nothing to
  latch on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A criterion is unlatched from the moment it exists, before any run has judged it",
       criterion: 1895 do
    scenario "a criterion added after the story was already certified" do
      given_ "a story certified ready for QA through its held task, its one criterion latched",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)
        context = a_held_ready_for_qa_task(context, story)
        {false, _} = complete_ready_for_qa(context)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "a second criterion is added, and its own spex fails while the first stays green",
            context do
        response = add_criterion(context, context.story, "It also works on Tuesdays")
        refute response.isError, inspect(response)

        story = Stories.get_story(context.scope, context.story.id)
        [new_criterion] = Enum.reject(story.criteria, &(&1.description == "It works"))

        {:ok, _} =
          Fixtures.record_problem(context.scope, "spex", %{
            file_path: Fixtures.spec_file_path(story, new_criterion),
            message: "Tuesday has not been implemented",
            severity: :error
          })

        context = context |> Map.put(:story, story) |> a_held_ready_for_qa_task(story)
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "certifying again is refused, naming the new criterion's own failing spex", context do
        {error?, text} = context.answer
        assert error?, text
        assert text =~ "spex", text
        {:ok, context}
      end

      then_ "the new criterion earned no latch of its own from the sibling that already had one",
            context do
        assert qa_stamp(context, context.story) == nil,
               "a criterion that has never had a green run must not let the story " <>
                 "re-certify on another criterion's latch"

        {:ok, context}
      end
    end
  end
end
