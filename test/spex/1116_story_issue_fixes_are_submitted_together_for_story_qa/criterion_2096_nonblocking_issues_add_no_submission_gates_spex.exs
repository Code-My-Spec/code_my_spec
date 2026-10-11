defmodule CodeMySpecSpex.Story1116.Criterion2096Spex do
  @moduledoc "No blocking issues add submission gates."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "No blocking issues add submission gates", criterion: 2096 do
    scenario "No blocking issues add submission gates" do
      given_ "a story team with the relevant issue work", context do
        context =
          context
          |> Bag.team()
          |> Bag.issue(:low, %{severity: :low})
          |> Bag.issue(:dismissed, %{status: :dismissed})

        {:ok, context}
      end

      when_ "the team reads its requirement graph", context do
        {:ok, Map.put(context, :requirements, Bag.requirements(context))}
      end

      then_ "the story workflow reflects the team's issue submissions", context do
        assert context.requirements =~ "ready_for_qa"
        refute context.requirements =~ context.low.title
        refute context.requirements =~ context.dismissed.title
        assert Bag.issue_text(context, :low) =~ "**Status:** accepted"
        assert Bag.issue_text(context, :dismissed) =~ "**Status:** dismissed"
        {:ok, context}
      end
    end
  end
end
