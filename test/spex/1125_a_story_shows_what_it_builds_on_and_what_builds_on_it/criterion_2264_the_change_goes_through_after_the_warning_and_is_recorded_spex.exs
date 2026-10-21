defmodule CodeMySpecSpex.Story1125.Criterion2264Spex do
  @moduledoc """
  Story 1125 — A story shows what it builds on and what builds on it.
  Criterion 2264 — The change goes through after the warning and is recorded.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A warned change can still go through, and is recorded", criterion: 2264 do
    scenario "making the change anyway records who made it and the dependent named" do
      given_ "story 12 builds on story 11, and an agent was warned when changing story 11",
             context do
        eleven = Deps.story(context.scope, "Eleven")
        twelve = Deps.story(context.scope, "Twelve")
        refute Deps.link(context.scope, twelve, eleven).error?

        warned = Deps.add_criterion(context.scope, eleven, "Eleven also does another thing")
        assert warned.text =~ "Story #{twelve}", "the premise: the change was warned about"
        {:ok, Map.merge(context, %{eleven: eleven, twelve: twelve})}
      end

      when_ "it makes the change anyway", context do
        result =
          Deps.add_criterion(context.scope, context.eleven, "Eleven also does another thing",
            proceed: true
          )

        refute result.error?, "the change did not go through: #{result.text}"
        {:ok, context}
      end

      then_ "the change is made", context do
        assert Deps.text(context.scope, context.eleven) =~ "Eleven also does another thing"
        {:ok, context}
      end

      then_ "and it is recorded who made it and that story 12 was named", context do
        text = Deps.text(context.scope, context.eleven)
        recorded = Deps.section(text, "Change history")

        assert recorded =~ context.user.email and recorded =~ "Story #{context.twelve}",
               "story 11 records no change by #{context.user.email} naming story 12:\n#{text}"

        {:ok, context}
      end
    end
  end
end
