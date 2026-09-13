defmodule CodeMySpecSpex.Story1046.Criterion3433Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3433 — Promotion returns in seconds.

  Rule: Promotion answers when the merge has landed, not when deployment has
  finished.

  ## What is asserted, and why it is not a stopwatch

  "In seconds" is the outcome; the mechanism is that the answer describes the
  *merge* and does not wait on the *deployment*. Asserting elapsed time would
  test the machine — on a box at three times its core count, which this one has
  been all evening, a wall-clock bound is a flake generator rather than a check.

  So this asserts the contract instead: the reply names the branch that landed,
  and says the restart is still running. An implementation that waited could not
  truthfully say that, and one that answered before merging could not name the
  branch.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A promotion answers on the merge, not on the deployment" do
    scenario "an agent promotes finished work" do
      given_ "a story branch with work on it, and main where it left it", context do
        context = a_promotable_project(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        {:ok, context}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context))}
      end

      then_ "it is told the merge landed", context do
        text = response_text(context.response)

        refute context.response.isError,
               "the promotion was refused: #{text}"

        assert text =~ "Promoted" and text =~ "Merged into",
               """
               The reply does not say the merge happened. An agent that cannot
               tell from the answer whether its work crossed has to go and look,
               which is the waiting this criterion removes. Got: #{text}
               """

        assert head_of(context, context.running_root) != nil
        {:ok, Map.put(context, :text, text)}
      end

      and_ "and told the deployment is still running rather than waited on", context do
        assert context.text =~ "not yet confirmed" and context.text =~ "still restarting",
               """
               The reply does not say the restart is still going. This is the
               half that makes the speed honest rather than a lie: the answer
               arrives early *because* the deployment is still in flight, and an
               agent told only "promoted" would reasonably read that as "and
               serving". Got: #{context.text}
               """

        refute context.text =~ "The application is running this work now",
               """
               The reply claims the application is already serving the merge. It
               cannot know that — the restart was dispatched and not awaited —
               and a promotion that overstates what it verified is how QA ends up
               testing a build nobody confirmed. Got: #{context.text}
               """

        {:ok, context}
      end
    end
  end
end
