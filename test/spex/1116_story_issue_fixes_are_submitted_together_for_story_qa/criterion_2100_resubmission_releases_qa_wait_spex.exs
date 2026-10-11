defmodule CodeMySpecSpex.Story1116.Criterion2100Spex do
  @moduledoc "Resubmission releases QA wait."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Resubmission releases QA wait", criterion: 2100 do
    scenario "Resubmission releases QA wait" do
      given_ "a story team with captured QA work", context do
        context =
          context
          |> Bag.team()
          |> Bag.issue(:a)
          |> Bag.issue(:b)
          |> Bag.submit(:a)
          |> Bag.submit(:b)
          |> Bag.ready()
          |> Bag.review()

        context = Bag.qa_result(context, "fail", [:a])
        {:ok, context}
      end

      when_ "coding resubmits A and certifies the story", context do
        context =
          context
          |> Bag.submit(:a, evidence: Bag.evidence() <> " Repaired QA finding.")
          |> Bag.ready()

        {:ok, context}
      end

      then_ "QA qualifies only for the reviewed story work", context do
        assert Bag.next(context, :qa) =~ "requirement_name=`qa_complete`"
        assert Bag.issue_text(context, :a) =~ "**Status:** accepted"
        assert Bag.issue_text(context, :b) =~ "**Status:** accepted"
        {:ok, context}
      end
    end
  end
end
