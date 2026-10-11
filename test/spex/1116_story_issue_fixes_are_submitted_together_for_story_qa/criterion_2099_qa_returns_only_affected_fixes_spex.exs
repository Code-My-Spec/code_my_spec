defmodule CodeMySpecSpex.Story1116.Criterion2099Spex do
  @moduledoc "QA returns only the affected fixes."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA returns only the affected fixes", criterion: 2099 do
    scenario "QA returns only the affected fixes" do
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

        {:ok, context}
      end

      when_ "QA reports the failing fix A", context do
        context = Bag.qa_result(context, "fail", [:a])
        {:ok, context}
      end

      then_ "QA qualifies only for the reviewed story work", context do
        assert Bag.next(context, :coding) =~ "entity_id=`#{context.a.id}`"
        refute Bag.next(context, :coding) =~ "entity_id=`#{context.b.id}`"
        assert Bag.issue_text(context, :b) =~ "submitted"
        assert Bag.next(context, :coding) =~ "# Story #{context.story.number}:"
        {:ok, context}
      end
    end
  end
end
