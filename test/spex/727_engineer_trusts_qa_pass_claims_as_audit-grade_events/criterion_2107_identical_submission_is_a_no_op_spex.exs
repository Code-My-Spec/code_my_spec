defmodule CodeMySpecSpex.Story727.Criterion2107Spex do
  @moduledoc "Repeating a submission is a no-op."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Repeating a submission is a no-op", criterion: 2107 do
    scenario "Repeating a submission is a no-op" do
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
        context = Map.put(context, :history_before, Bag.history(context))
        context = Map.put(context, :issue_before, Bag.issue_text(context, :a))
        {:ok, context}
      end

      when_ "coding repeats the identical submission", context do
        context = Bag.submit(context, :a)
        {:ok, context}
      end

      then_ "QA qualifies only for the reviewed story work", context do
        assert Bag.history(context) == context.history_before
        assert Bag.issue_text(context, :a) == context.issue_before
        assert Bag.qa_requirements(context) =~ context.story.title
        {:ok, context}
      end
    end
  end
end
