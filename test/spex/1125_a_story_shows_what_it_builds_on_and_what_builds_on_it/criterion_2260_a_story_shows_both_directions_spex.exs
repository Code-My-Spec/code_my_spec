defmodule CodeMySpecSpex.Story1125.Criterion2260Spex do
  @moduledoc """
  Story 1125 — A story shows what it builds on and what builds on it.
  Criterion 2260 — A story shows both directions.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story shows both directions", criterion: 2260 do
    scenario "a story in the middle shows what it builds on and what builds on it" do
      given_ "story 11 builds on story 10, and story 12 builds on story 11", context do
        ten = Deps.story(context.scope, "Ten")
        eleven = Deps.story(context.scope, "Eleven")
        twelve = Deps.story(context.scope, "Twelve")
        refute Deps.link(context.scope, eleven, ten).error?
        refute Deps.link(context.scope, twelve, eleven).error?
        {:ok, Map.merge(context, %{ten: ten, eleven: eleven, twelve: twelve})}
      end

      when_ "I look at story 11", context do
        {:ok, Map.put(context, :text, Deps.text(context.scope, context.eleven))}
      end

      then_ "it shows it builds on story 10, with its number, title and status", context do
        assert Deps.section(context.text, "Builds on") =~
                 ~r/Story #{context.ten}: Ten \(\w[\w ]*\)/,
               "get_story showed:\n#{context.text}"

        {:ok, context}
      end

      then_ "and story 12 builds on it, with its number, title and status", context do
        assert Deps.section(context.text, "Built on by") =~
                 ~r/Story #{context.twelve}: Twelve \(\w[\w ]*\)/,
               "get_story showed:\n#{context.text}"

        {:ok, context}
      end
    end
  end
end
