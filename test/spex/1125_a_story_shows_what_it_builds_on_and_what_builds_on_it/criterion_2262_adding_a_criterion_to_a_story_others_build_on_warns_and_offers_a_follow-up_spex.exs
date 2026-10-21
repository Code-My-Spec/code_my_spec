defmodule CodeMySpecSpex.Story1125.Criterion2262Spex do
  @moduledoc """
  Story 1125 — A story shows what it builds on and what builds on it.
  Criterion 2262 — Adding a criterion to a story others build on warns and offers a follow-up.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Changing a story others build on warns first", criterion: 2262 do
    scenario "adding a criterion warns, naming the dependent, and offers a follow-up story" do
      given_ "story 12 builds on story 11", context do
        eleven = Deps.story(context.scope, "Eleven")
        twelve = Deps.story(context.scope, "Twelve")
        refute Deps.link(context.scope, twelve, eleven).error?
        {:ok, Map.merge(context, %{eleven: eleven, twelve: twelve})}
      end

      when_ "an agent adds a criterion to story 11", context do
        result =
          Deps.add_criterion(context.scope, context.eleven, "Eleven also does another thing")

        {:ok, Map.put(context, :result, result)}
      end

      then_ "it is warned that story 12 builds on story 11", context do
        assert context.result.text =~ "Story #{context.twelve}" and
                 context.result.text =~ ~r/builds on/i,
               "no warning naming story 12 as building on story 11: #{context.result.text}"

        {:ok, context}
      end

      then_ "and offered a follow-up story that builds on story 11 instead", context do
        assert context.result.text =~ ~r/follow-up/i,
               "no follow-up story was offered: #{context.result.text}"

        {:ok, context}
      end
    end
  end
end
