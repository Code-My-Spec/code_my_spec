defmodule CodeMySpecSpex.Story727.Criterion2109Spex do
  @moduledoc "A newly accepted blocker stops progress before submission."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A newly accepted blocker stops progress before submission", criterion: 2109 do
    scenario "A newly accepted blocker stops progress before submission" do
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

      when_ "a new blocking issue is accepted", context do
        context = Bag.finding(context, :new_blocker, :accepted)
        {:ok, context}
      end

      then_ "QA qualifies only for the reviewed story work", context do
        assert Bag.next(context, :coding) =~ "entity_id=`#{context.new_blocker.id}`"
        assert Bag.issue_text(context, :new_blocker) =~ "**Status:** accepted"
        refute Bag.next(context, :qa) =~ "requirement_name=`qa_complete`"
        refute Bag.history(context) =~ "invalidated"
        {:ok, context}
      end

      when_ "coding submits the newly accepted blocker", context do
        {:ok, Bag.submit(context, :new_blocker)}
      end

      then_ "the prior pass is invalidated and fresh QA is needed", context do
        assert Bag.history(context) =~ "invalidated"
        refute Bag.qa_requirements(context) =~ context.story.title
        assert Bag.issue_text(context, :new_blocker) =~ "submitted"
        {:ok, context}
      end
    end
  end
end
