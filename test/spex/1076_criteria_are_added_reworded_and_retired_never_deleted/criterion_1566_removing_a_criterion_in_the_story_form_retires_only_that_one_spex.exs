defmodule CodeMySpecSpex.Story1076.Criterion4690Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4690 — Removing a criterion in the story form retires only that one.

  Covers Rule "A criterion keeps its number for its whole life".

  The form's remove button used to delete the row through
  `cast_assoc(on_replace: :delete)`. Under the rule there is no delete: the
  removed criterion is retired, and the ones left keep their numbers.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The story form retires what it removes", criterion: 1566 do
    scenario "removing the middle criterion retires it and leaves the others" do
      given_ "story A has three criteria in the story form", context do
        story =
          CriterionScript.create_story(context.scope, "Story A", [
            "A first thing happens",
            "A second thing happens",
            "A third thing happens"
          ])

        text = CriterionScript.story_text(context.scope, story)
        [first, second, third] = CriterionScript.numbers(text)

        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/stories/#{CriterionScript.story_number(text)}/edit"
          )

        {:ok,
         Map.merge(context, %{
           story: story,
           view: view,
           first: first,
           second: second,
           third: third
         })}
      end

      when_ "the PM removes the second one and saves", context do
        context.view
        |> form("#story-form")
        |> render_submit(%{"story" => %{"criteria_drop" => ["1"]}})

        {:ok, context}
      end

      then_ "the second one is retired", context do
        result =
          CriterionScript.run(context.scope, """
          return get_criterion({ criterion_number = #{context.second} })
          """)

        refute result.error?,
               "criterion #{context.second} should still be readable after removal. Got: #{result.text}"

        assert result.text =~ ~r/retired/i,
               "criterion #{context.second} should read as retired. Got: #{result.text}"

        {:ok, context}
      end

      and_ "the first and third keep their numbers", context do
        text = CriterionScript.story_text(context.scope, context.story)

        assert CriterionScript.numbers(text) == [context.first, context.third],
               "expected the story's active criteria to be #{context.first} and #{context.third}. " <>
                 "get_story showed:\n#{text}"

        {:ok, context}
      end
    end
  end
end
