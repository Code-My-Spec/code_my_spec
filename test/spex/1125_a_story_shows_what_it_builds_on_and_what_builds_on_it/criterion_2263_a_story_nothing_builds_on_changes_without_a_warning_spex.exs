defmodule CodeMySpecSpex.Story1125.Criterion2263Spex do
  @moduledoc """
  Story 1125 — A story shows what it builds on and what builds on it.
  Criterion 2263 — A story nothing builds on changes without a warning.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story nothing builds on changes freely", criterion: 2263 do
    scenario "adding a criterion to a story nothing builds on adds it with no warning" do
      given_ "nothing builds on story 13", context do
        {:ok, Map.put(context, :thirteen, Deps.story(context.scope, "Thirteen"))}
      end

      when_ "an agent adds a criterion to story 13", context do
        result =
          Deps.add_criterion(context.scope, context.thirteen, "Thirteen also does another thing")

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the criterion is added", context do
        refute context.result.error?, "add_criterion failed: #{context.result.text}"

        assert Deps.text(context.scope, context.thirteen) =~ "Thirteen also does another thing"
        {:ok, context}
      end

      then_ "with no warning", context do
        refute context.result.text =~ ~r/builds on|follow-up/i,
               "a story nothing builds on warned: #{context.result.text}"

        {:ok, context}
      end
    end
  end
end
