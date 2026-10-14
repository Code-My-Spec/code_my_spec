defmodule CodeMySpecSpex.Story1116.Criterion2101Spex do
  @moduledoc "A shared story QA pass completes its reviewed fixes only when promotion lands."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.PromotionHelpers, as: Promotion
  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Passing QA waits for landing", criterion: 2101 do
    scenario "The story and its reviewed fixes land together" do
      given_ "a story whose submitted issue fixes passed shared QA", context do
        {:ok, Bag.promotable(context)}
      end

      then_ "QA has not resolved either issue or freed the team", context do
        assert Bag.issue_text(context, :a) =~ "**Status:** accepted"
        assert Bag.issue_text(context, :b) =~ "**Status:** accepted"
        assert Bag.next(context, :coding) =~ "# Story #{context.story.number}:"
        {:ok, context}
      end

      when_ "the team promotes the story and the gate passes", context do
        response = Promotion.promote(context, context.story.number)
        refute response.isError, response_text(response)
        context = Promotion.the_gate_answers(context)
        {:ok, Map.put(context, :outcome, Promotion.what_the_agent_was_told(context))}
      end

      then_ "both reviewed fixes resolve on landing", context do
        assert context.outcome =~ "landed on main"
        assert Bag.issue_text(context, :a) =~ "**Status:** resolved"
        assert Bag.issue_text(context, :b) =~ "**Status:** resolved"
        refute Bag.next(context, :coding) =~ "# Story #{context.story.number}:"
        refute Bag.next(context, :qa) =~ "# Story #{context.story.number}:"
        {:ok, context}
      end
    end
  end
end
