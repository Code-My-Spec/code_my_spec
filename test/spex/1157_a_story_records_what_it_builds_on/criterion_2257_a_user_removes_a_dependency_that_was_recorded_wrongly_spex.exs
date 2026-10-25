defmodule CodeMySpecSpex.Story1157.Criterion2257Spex do
  @moduledoc """
  Story 1157 — A story shows what it builds on and what builds on it.
  Criterion 2257 — A user removes a dependency that was recorded wrongly.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A wrongly recorded dependency is removed", criterion: 2257 do
    scenario "removing the link leaves the story building on nothing" do
      given_ "story 11 builds on story 10", context do
        ten = Deps.story(context.scope, "Ten")
        eleven = Deps.story(context.scope, "Eleven")
        result = Deps.link(context.scope, eleven, ten)
        refute result.error?, "add_story_dependency failed: #{result.text}"
        {:ok, Map.merge(context, %{ten: ten, eleven: eleven})}
      end

      when_ "I remove that link", context do
        result = Deps.unlink(context.scope, context.eleven, context.ten)
        refute result.error?, "remove_story_dependency failed: #{result.text}"
        {:ok, context}
      end

      then_ "story 11 builds on nothing", context do
        text = Deps.text(context.scope, context.eleven)

        assert text =~ to_string(context.eleven)
        assert text =~ ~r/Builds on/

        refute Deps.section(text, "Builds on") =~ "Story #{context.ten}",
               "story 11 still shows it builds on story 10. get_story showed:\n#{text}"

        {:ok, context}
      end
    end
  end
end
