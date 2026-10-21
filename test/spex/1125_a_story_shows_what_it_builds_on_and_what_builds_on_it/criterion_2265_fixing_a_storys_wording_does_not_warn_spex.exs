defmodule CodeMySpecSpex.Story1125.Criterion2265Spex do
  @moduledoc """
  Story 1125 — A story shows what it builds on and what builds on it.
  Criterion 2265 — Fixing a story's wording does not warn.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Fixing a story's wording does not warn", criterion: 2265 do
    scenario "correcting a typo in the title of a story others build on changes it silently" do
      given_ "story 12 builds on story 11", context do
        eleven = Deps.story(context.scope, "Elevn")
        twelve = Deps.story(context.scope, "Twelve")
        refute Deps.link(context.scope, twelve, eleven).error?
        {:ok, Map.merge(context, %{eleven: eleven, twelve: twelve})}
      end

      when_ "I correct a typo in story 11's title", context do
        {:ok, Map.put(context, :result, Deps.rename(context.scope, context.eleven, "Eleven"))}
      end

      then_ "the title changes", context do
        refute context.result.error?, "update_story failed: #{context.result.text}"
        assert Deps.text(context.scope, context.eleven) =~ ~r/## Story \d+: Eleven\b/
        {:ok, context}
      end

      then_ "with no warning", context do
        refute context.result.text =~ ~r/builds on|follow-up/i,
               "correcting a title warned: #{context.result.text}"

        {:ok, context}
      end
    end
  end
end
