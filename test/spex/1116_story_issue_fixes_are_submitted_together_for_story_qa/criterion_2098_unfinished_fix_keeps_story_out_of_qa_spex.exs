defmodule CodeMySpecSpex.Story1116.Criterion2098Spex do
  @moduledoc "An unfinished fix keeps the story out of QA."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An unfinished fix keeps the story out of QA", criterion: 2098 do
    scenario "An unfinished fix keeps the story out of QA" do
      given_ "a story team with the relevant issue work", context do
        context = context |> Bag.team() |> Bag.issue(:a) |> Bag.issue(:b) |> Bag.submit(:a)
        {:ok, context}
      end

      when_ "the team asks for its next work", context do
        {:ok,
         Map.merge(context, %{
           coding_work: Bag.next(context, :coding),
           qa_work: Bag.next(context, :qa)
         })}
      end

      then_ "the story workflow reflects the team's issue submissions", context do
        assert context.coding_work =~ "entity_id=`#{context.b.id}`"
        refute context.coding_work =~ "entity_id=`#{context.a.id}`"
        refute context.qa_work =~ "requirement_name=`qa_complete`"
        assert Bag.issue_text(context, :a) =~ "**Status:** accepted"
        {:ok, context}
      end
    end
  end
end
