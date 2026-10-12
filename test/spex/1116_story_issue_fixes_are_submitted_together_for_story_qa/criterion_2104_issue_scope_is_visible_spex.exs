defmodule CodeMySpecSpex.Story1116.Criterion2104Spex do
  @moduledoc "Issue scope remains visible during fixing."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Issue scope remains visible during fixing", criterion: 2104 do
    scenario "Issue scope remains visible during fixing" do
      given_ "a story team with the relevant issue work", context do
        context =
          context
          |> Bag.team()
          |> Bag.issue(:app, %{scope: :app})
          |> Bag.issue(:qa_issue, %{scope: :qa})
          |> Bag.issue(:docs, %{scope: :docs})

        {:ok, context}
      end

      when_ "coding reads each of its issues", context do
        {:ok,
         Map.put(
           context,
           :issue_details,
           Enum.map([:app, :qa_issue, :docs], &Bag.issue_text(context, &1))
         )}
      end

      then_ "the story workflow reflects the team's issue submissions", context do
        for {text, scope} <- Enum.zip(context.issue_details, ["app", "qa", "docs"]) do
          assert text =~ "**Scope:** #{scope}"
          assert text =~ "**Status:** accepted"
        end

        {:ok, context}
      end
    end
  end
end
