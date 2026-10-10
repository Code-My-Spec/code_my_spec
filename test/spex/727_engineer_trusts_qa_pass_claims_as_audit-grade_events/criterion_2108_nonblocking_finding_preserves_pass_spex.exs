defmodule CodeMySpecSpex.Story727.Criterion2108Spex do
  @moduledoc "Incoming and nonblocking findings preserve the existing pass."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Incoming and nonblocking findings preserve the existing pass", criterion: 2108 do
    scenario "Incoming and nonblocking findings preserve the existing pass" do
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

        context = Bag.qa_result(context, "pass")
        {:ok, context}
      end

      when_ "a nonblocking finding is recorded", context do
        context = Bag.finding(context, :finding, :dismissed)
        {:ok, context}
      end

      then_ "QA qualifies only for the reviewed story work", context do
        assert Bag.qa_requirements(context) =~ context.story.title
        refute Bag.history(context) =~ "invalidated"
        assert Bag.issue_text(context, :finding) =~ "**Status:** dismissed"
        {:ok, context}
      end
    end
  end
end
