defmodule CodeMySpecSpex.Story1046.Criterion3436Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3436 — A refusal reads as ordinary, not as a fault.

  Rule: Whether a merge can succeed is decided before it is attempted, and
  refused plainly when it cannot.

  ## Why a criterion about wording

  Requiring the promoting branch to contain main means promotion now refuses on
  plain divergence, not only on conflict. Divergence is what happens when
  somebody else promotes while you are working, which on this machine happened
  three times in two hours on 2026-09-12. So this refusal becomes the most-read
  string in the system, and what it *implies* is as much the product as what it
  does.

  A refusal that reads like an error the agent caused sends it looking for a
  defect that is not there — and an agent with no defect to find escalates, or
  retries, or starts investigating its own branch. That is a real cost paid
  repeatedly, and it is invisible in any test that only checks the refusal
  happened.

  ## The three things asserted

  It says divergence is normal. It says nothing was merged, so the reader knows
  the shared checkout is untouched without going to look. It names the one
  command that fixes it. Each is a separate failure if missing: normality
  without a remedy leaves them stuck, a remedy without normality leaves them
  suspicious, and neither without the reassurance sends them to check the target
  by hand.
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

  spex "Somebody else promoted while this agent was working" do
    scenario "the branch has diverged through nobody's mistake" do
      given_ "a story branch with work on it", context do
        context = a_promotable_project(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        {:ok, context}
      end

      given_ "and somebody else's work landed on main meanwhile", context do
        write(context.running_root, "lib/broken_oaths/diplomacy/treaty.ex", treaty())
        {_, 0} = git(context, context.running_root, ["add", "-A"])

        {_, 0} =
          git(context, context.running_root, ["commit", "-q", "-m", "somebody else's promotion"])

        {:ok, context}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context))}
      end

      then_ "the refusal says this is ordinary", context do
        text = response_text(context.response)

        assert context.response.isError, "the premise failed: it was not refused"

        assert text =~ "not a mistake" or text =~ "normal",
               """
               The refusal does not say divergence is ordinary. Somebody else
               promoting while you worked is the commonest thing that happens on
               a shared checkout, and a refusal that reads like a fault sends an
               agent looking for a defect that does not exist. Got: #{text}
               """

        {:ok, Map.put(context, :text, text)}
      end

      and_ "tells the reader the target was left alone", context do
        assert context.text =~ "Nothing was merged" or context.text =~ "unchanged",
               """
               The refusal does not say the running copy is untouched. Without
               that the reader has to go and check a shared checkout by hand to
               find out whether a half-done merge is sitting on it. Got:
               #{context.text}
               """

        {:ok, context}
      end

      and_ "and names the one command that fixes it", context do
        assert context.text =~ "git merge",
               """
               The refusal does not name the remedy. Saying divergence is normal
               and then not saying what to do about it is worse than saying
               nothing — it tells the agent this is expected and leaves it stuck.
               Got: #{context.text}
               """

        {:ok, context}
      end
    end
  end
end
