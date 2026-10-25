defmodule CodeMySpecSpex.Story1157.Criterion2256Spex do
  @moduledoc """
  Story 1157 — A story shows what it builds on and what builds on it.
  Criterion 2256 — The product agent records a split story's dependency.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A split story records what it builds on", criterion: 2256 do
    scenario "the product agent splits off a story and records the dependency" do
      given_ "story 10 exists", context do
        {:ok, Map.put(context, :ten, Deps.story(context.scope, "Ten"))}
      end

      when_ "the product agent splits off story 11 and records that 11 builds on 10", context do
        eleven = Deps.story(context.scope, "Eleven")
        result = Deps.link(context.scope, eleven, context.ten)
        refute result.error?, "add_story_dependency failed: #{result.text}"
        {:ok, Map.put(context, :eleven, eleven)}
      end

      then_ "story 11 builds on story 10", context do
        text = Deps.text(context.scope, context.eleven)

        assert Deps.section(text, "Builds on") =~ "Story #{context.ten}",
               "story 11 does not show it builds on story 10. get_story showed:\n#{text}"

        {:ok, context}
      end
    end
  end
end
