defmodule CodeMySpecSpex.Story1116.Criterion2103Spex do
  @moduledoc "A submitted fix carries reviewable evidence."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A submitted fix carries reviewable evidence", criterion: 2103 do
    scenario "A submitted fix carries reviewable evidence" do
      given_ "a story team with the relevant issue work", context do
        {:ok, context |> Bag.team() |> Bag.issue(:a)}
      end

      when_ "coding submits its fix with change files and verification", context do
        {:ok, Bag.submit(context, :a)}
      end

      then_ "the story workflow reflects the team's issue submissions", context do
        text = Bag.issue_text(context, :a)
        assert text =~ "**Status:** accepted"
        assert text =~ "submitted"
        assert text =~ "lib/example.ex"
        assert text =~ "mix test"
        assert text =~ "Fixed the missing delivery"
        {:ok, context}
      end
    end
  end
end
