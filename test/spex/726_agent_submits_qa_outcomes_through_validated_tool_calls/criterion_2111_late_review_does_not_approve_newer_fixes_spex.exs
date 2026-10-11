defmodule CodeMySpecSpex.Story726.Criterion2111Spex do
  @moduledoc "A late result cannot approve newer submissions."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A late result cannot approve newer submissions", criterion: 2111 do
    scenario "A late result cannot approve newer submissions" do
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

        context = Bag.submit(context, :a, evidence: Bag.evidence() <> " New fix.")
        {:ok, context}
      end

      when_ "the original QA review reports pass", context do
        context = Bag.qa_result(context, "pass")
        {:ok, context}
      end

      then_ "QA qualifies only for the reviewed story work", context do
        history = Bag.history(context)
        assert history =~ "pass"
        assert history =~ ~r/stale|superseded/i
        refute Bag.qa_requirements(context) =~ context.story.title
        assert Bag.issue_text(context, :a) =~ "**Status:** accepted"
        {:ok, context}
      end
    end
  end
end
