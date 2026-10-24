defmodule CodeMySpecSpex.Story1076.Criterion4697Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4697 — Restoring a retired criterion brings back the same number.

  Covers Rule "A retired criterion can be restored under its number".

  Restoring under the old number keeps a mistaken retire cheap for everything
  but the spec: retiring deletes the spex naming the number (issue 73e302aa,
  decided with John 2026-10-21), so the restored criterion is active again and
  needs a spec written for it again.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Restoring brings the same criterion back", criterion: 1573 do
    scenario "a restored criterion is active under its number and needs its spec again" do
      given_ "a criterion on story A with a spec naming it was retired", context do
        story =
          CriterionScript.create_story(context.scope, "Story A", ["A thing retired by mistake"])

        text = CriterionScript.story_text(context.scope, story)
        [number] = CriterionScript.numbers(text)

        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            "test/spex/#{CriterionScript.story_number(text)}_story_a/criterion_#{number}_spex.exs",
            spex_naming(number)
          )

        Fixtures.deliver_manifest(context.scope)

        result =
          CriterionScript.run(context.scope, """
          return retire_criterion({ criterion_number = #{number} })
          """)

        refute result.error?, "retire_criterion failed: #{result.text}"

        {:ok, context |> Map.put(:story, story) |> Map.put(:number, number)}
      end

      when_ "the agent restores it", context do
        result =
          CriterionScript.run(context.scope, """
          return restore_criterion({ criterion_number = #{context.number} })
          """)

        refute result.error?, "restore_criterion failed: #{result.text}"
        {:ok, context}
      end

      then_ "the criterion is active on story A again under the same number", context do
        text = CriterionScript.story_text(context.scope, context.story)

        assert text =~ "A thing retired by mistake (criterion #{context.number})",
               "expected criterion #{context.number} active again. get_story showed:\n#{text}"

        {:ok, context}
      end

      and_ "its spec was deleted when it was retired, so it is uncovered until rewritten",
           context do
        refute CriterionScript.specs_exist?(context.scope, context.story),
               "the spec naming criterion #{context.number} should have gone when it was retired"

        {:ok, context}
      end
    end
  end

  defp spex_naming(number) do
    """
    defmodule CodeMySpecSpex.Sample.Criterion#{number}Spex do
      use CodeMySpecSpex.Case

      spex "Criterion #{number}", criterion: #{number} do
        scenario "it happens" do
          given_ "a state", context do
            {:ok, context}
          end

          when_ "an action", context do
            {:ok, context}
          end

          then_ "an outcome", context do
            {:ok, context}
          end
        end
      end
    end
    """
  end
end
