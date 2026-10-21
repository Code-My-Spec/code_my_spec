defmodule CodeMySpecSpex.Story1125.Criterion2266Spex do
  @moduledoc """
  Story 1125 — A story shows what it builds on and what builds on it.
  Criterion 2266 — Already-shipped dependents are still named.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.StoryDependencyScript, as: Deps
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Already-shipped dependents are still named", criterion: 2266 do
    scenario "the warning names a promoted dependent and shows it as promoted" do
      given_ "story 12 builds on story 11, and story 12 is promoted", context do
        context = context |> Slice.staff() |> Slice.complete() |> Slice.land()
        twelve = context.story.number
        eleven = Deps.story(context.scope, "Eleven")
        refute Deps.link(context.scope, twelve, eleven).error?
        {:ok, Map.merge(context, %{eleven: eleven, twelve: twelve})}
      end

      when_ "an agent edits a criterion on story 11", context do
        [first | _] = CriterionScript.numbers(Deps.text(context.scope, context.eleven))

        {:ok, Map.put(context, :result, Deps.retire_criterion(context.scope, first))}
      end

      then_ "the warning names story 12 and shows it as promoted", context do
        assert context.result.text =~ ~r/Story #{context.twelve}[^\n]*promoted/i,
               "the warning does not show story 12 as promoted: #{context.result.text}"

        {:ok, context}
      end
    end
  end
end
