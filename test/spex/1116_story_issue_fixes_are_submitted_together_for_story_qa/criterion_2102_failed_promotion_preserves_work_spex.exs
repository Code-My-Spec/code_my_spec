defmodule CodeMySpecSpex.Story1116.Criterion2102Spex do
  @moduledoc "A failed promotion keeps the story and submitted issues assigned."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.PromotionHelpers, as: Promotion
  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "Failed promotion preserves the unfinished work", criterion: 2102 do
    scenario "A gate failure cannot complete a story issue bag" do
      given_ "a story whose submitted issue fixes passed shared QA", context do
        {:ok, Bag.promotable(context)}
      end

      when_ "the team promotes the story and the gate reports a compiler error", context do
        response = Promotion.promote(context, context.story.number)
        refute response.isError, response_text(response)

        context =
          Promotion.the_gate_answers(context, %{
            "compiler" => [
              %{
                "file" => "lib/broken_oaths/diplomacy/war.ex",
                "message" => "cannot compile story",
                "severity" => "error"
              }
            ]
          })

        {:ok, Map.put(context, :outcome, Promotion.what_the_agent_was_told(context))}
      end

      then_ "the failed landing leaves both fixes unresolved and the team assigned", context do
        refute context.outcome =~ "landed on main"
        assert context.outcome =~ "nothing of it landed"
        assert context.outcome =~ "cannot compile story"
        assert Bag.issue_text(context, :a) =~ "**Status:** accepted"
        assert Bag.issue_text(context, :b) =~ "**Status:** accepted"
        assert Bag.next(context, :coding) =~ "# Story #{context.story.number}:"
        assert Bag.next(context, :qa) =~ "# Story #{context.story.number}:"
        {:ok, context}
      end
    end
  end
end
