defmodule CodeMySpecSpex.Story726.Criterion2112Spex do
  @moduledoc "A stale result cannot replace a newer qualifying review."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A stale result cannot replace a newer qualifying review", criterion: 2112 do
    scenario "A stale result cannot replace a newer qualifying review" do
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

        context =
          context
          |> Bag.submit(:a, evidence: Bag.evidence() <> " New fix.")
          |> Bag.ready()
          |> Bag.review(:fresh_review)

        context = Bag.qa_result(context, "pass", [], :fresh_review)
        {:ok, context}
      end

      when_ "the older review reports failure", context do
        context = Bag.qa_result(context, "fail", [:a])
        {:ok, context}
      end

      then_ "QA qualifies only for the reviewed story work", context do
        assert Bag.qa_requirements(context) =~ context.story.title
        assert Bag.issue_text(context, :a) =~ "submitted"
        history = Bag.history(context)
        assert history =~ "pass"
        assert history =~ "fail"
        assert history =~ ~r/stale|superseded/i
        {:ok, context}
      end
    end
  end
end
