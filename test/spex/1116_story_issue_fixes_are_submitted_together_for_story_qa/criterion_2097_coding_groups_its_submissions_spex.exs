defmodule CodeMySpecSpex.Story1116.Criterion2097Spex do
  @moduledoc "Coding chooses how to group its fixes."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Coding chooses how to group its fixes", criterion: 2097 do
    scenario "Coding chooses how to group its fixes" do
      given_ "a story team with the relevant issue work", context do
        context = context |> Bag.team() |> Bag.issue(:a) |> Bag.issue(:b) |> Bag.issue(:c)
        context = Bag.submit(context, :a)
        {:ok, context}
      end

      when_ "coding submits the remaining fixes together without waiting for QA", context do
        context = context |> Bag.submit(:b) |> Bag.submit(:c)
        {:ok, context}
      end

      then_ "the story workflow reflects the team's issue submissions", context do
        for key <- [:a, :b, :c] do
          text = Bag.issue_text(context, key)
          assert text =~ "**Status:** accepted"
          assert text =~ "submitted"
          assert text =~ Bag.evidence()
        end

        refute Bag.next(context, :coding) =~ "requirement_name=`submitted`"
        {:ok, context}
      end
    end
  end
end
