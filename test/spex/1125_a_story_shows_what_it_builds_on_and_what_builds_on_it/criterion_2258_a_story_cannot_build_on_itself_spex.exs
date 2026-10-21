defmodule CodeMySpecSpex.Story1125.Criterion2258Spex do
  @moduledoc """
  Story 1125 — A story shows what it builds on and what builds on it.
  Criterion 2258 — A story cannot build on itself.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story cannot build on itself", criterion: 2258 do
    scenario "recording a story as building on itself is refused" do
      given_ "story 10 exists", context do
        {:ok, Map.put(context, :ten, Deps.story(context.scope, "Ten"))}
      end

      when_ "an agent records that story 10 builds on story 10", context do
        {:ok, Map.put(context, :result, Deps.link(context.scope, context.ten, context.ten))}
      end

      then_ "it is refused, saying a story cannot build on itself", context do
        assert context.result.text =~ ~r/cannot build on itself/i,
               "the refusal does not say a story cannot build on itself: #{context.result.text}"

        {:ok, context}
      end
    end
  end
end
