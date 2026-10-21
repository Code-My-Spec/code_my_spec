defmodule CodeMySpecSpex.Story1125.Criterion2261Spex do
  @moduledoc """
  Story 1125 — A story shows what it builds on and what builds on it.
  Criterion 2261 — An agent reading a story sees what builds on it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent reading a story sees what builds on it", criterion: 2261 do
    scenario "get_story names the story that builds on the one read" do
      given_ "story 12 builds on story 11", context do
        eleven = Deps.story(context.scope, "Eleven")
        twelve = Deps.story(context.scope, "Twelve")
        refute Deps.link(context.scope, twelve, eleven).error?
        {:ok, Map.merge(context, %{eleven: eleven, twelve: twelve})}
      end

      when_ "an agent reads story 11 with get_story", context do
        {:ok, Map.put(context, :text, Deps.text(context.scope, context.eleven))}
      end

      then_ "the reply names story 12 as building on it", context do
        assert Deps.section(context.text, "Built on by") =~ "Story #{context.twelve}",
               "get_story did not name story 12 as building on story 11:\n#{context.text}"

        {:ok, context}
      end
    end
  end
end
