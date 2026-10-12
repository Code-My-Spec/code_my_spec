defmodule CodeMySpecSpex.Story1116.Criterion2095Spex do
  @moduledoc "Issue submissions fan out and join story readiness."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Issue submissions fan out and join story readiness", criterion: 2095 do
    scenario "Issue submissions fan out and join story readiness" do
      given_ "a story team with the relevant issue work", context do
        context = context |> Bag.team() |> Bag.issue(:a) |> Bag.issue(:b)
        {:ok, context}
      end

      when_ "the team reads its requirement graph", context do
        {:ok, Map.put(context, :requirements, Bag.requirements(context))}
      end

      then_ "the story workflow reflects the team's issue submissions", context do
        assert context.requirements =~ "submitted"
        assert context.requirements =~ context.a.title
        assert context.requirements =~ context.b.title
        assert context.requirements =~ "ready_for_qa"
        refute context.requirements =~ "story_issues_resolved"
        {:ok, context}
      end
    end
  end
end
