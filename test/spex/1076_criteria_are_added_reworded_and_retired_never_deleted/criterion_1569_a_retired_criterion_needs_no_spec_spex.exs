defmodule CodeMySpecSpex.Story1076.Criterion4693Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4693 — A retired criterion needs no spec.

  Covers Rule "A retired criterion no longer counts toward its story".

  Each spec names its criterion on the `spex` call, which is how story 1077
  binds a file to a criterion.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retired criteria drop out of coverage", criterion: 1569 do
    scenario "two active criteria with specs and one retired without satisfy bdd_specs_exist" do
      given_ "story A has two active criteria with specs and a retired one without", context do
        story =
          CriterionScript.create_story(context.scope, "Story A", [
            "A first thing happens",
            "A second thing happens",
            "A third thing that was dropped"
          ])

        text = CriterionScript.story_text(context.scope, story)
        [first, second, third] = CriterionScript.numbers(text)
        number = CriterionScript.story_number(text)

        for n <- [first, second] do
          :ok =
            Environments.write_file(
              context.environment,
              "test/spex/#{number}_story_a/criterion_#{n}_spex.exs",
              spex_naming(n)
            )
        end

        result =
          CriterionScript.run(context.scope, """
          return retire_criterion({ criterion_id = "#{third}" })
          """)

        refute result.error?, "retire_criterion failed: #{result.text}"

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the graph is computed", context do
        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "story A's specs exist", context do
        assert Fixtures.requirement_satisfied?(
                 context.scope,
                 "bdd_specs_exist",
                 :story,
                 String.to_integer(context.story)
               ),
               "every active criterion has a spec; the retired one should not be asked for one"

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
