defmodule CodeMySpecSpex.Story70.Criterion1620Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1620 — Re-executing a proposal with a changed dependency list adds the new dependencies and removes the dropped ones.

  Re-executing used to leave an existing spec stub alone, so a changed
  dependency list was silently lost (3aeb66cf).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Re-executing a proposal with a changed dependency list adds the new dependencies and removes the dropped ones",
    criterion: 1620 do
    scenario "one dependency is swapped for another" do
      given_ "an executed proposal where Feature depends on Billing", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "A feature",
            description: "Needs a feature",
            acceptance_criteria: ["It works"]
          )

        contexts = [{"Feature", []}, {"Billing", []}, {"Accounts", []}]

        base = [
          {"FeatureLive", "Feature"},
          {"FeatureLive", "Billing"},
          {"FeatureLive", "Accounts"}
        ]

        execute_proposal!(
          context,
          proposal(context, story.number, contexts, base ++ [{"Feature", "Billing"}])
        )

        assert architecture(context) =~ edge(context, "Feature", "Billing")

        {:ok, Map.merge(context, %{story: story, contexts: contexts, base: base})}
      end

      when_ "the architect re-executes it with Feature depending on Accounts instead", context do
        execute_proposal!(
          context,
          proposal(
            context,
            context.story.number,
            context.contexts,
            context.base ++ [{"Feature", "Accounts"}]
          )
        )

        {:ok, context}
      end

      then_ "the new dependency is there and the dropped one is gone", context do
        assert architecture(context) =~ edge(context, "Feature", "Accounts")
        refute architecture(context) =~ edge(context, "Feature", "Billing")
        {:ok, context}
      end
    end
  end
end
