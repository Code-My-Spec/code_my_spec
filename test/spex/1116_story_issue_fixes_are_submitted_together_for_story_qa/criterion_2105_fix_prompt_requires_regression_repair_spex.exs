defmodule CodeMySpecSpex.Story1116.Criterion2105Spex do
  @moduledoc "A regression must be fixed before submission."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A regression must be fixed before submission", criterion: 2105 do
    scenario "A regression must be fixed before submission" do
      given_ "a story team with the relevant issue work", context do
        {:ok, context |> Bag.team() |> Bag.issue(:a)}
      end

      when_ "coding starts fixing its issue", context do
        {:ok, Map.put(context, :prompt, Bag.start_fix(context, :a))}
      end

      then_ "the story workflow reflects the team's issue submissions", context do
        assert context.prompt =~ ~r/regression/i
        assert context.prompt =~ "submit_story_issue"
        assert context.prompt =~ ~r/verification|verify|validation/i
        assert context.prompt =~ ~r/skip|silenc|pending/i
        {:ok, context}
      end
    end
  end
end
