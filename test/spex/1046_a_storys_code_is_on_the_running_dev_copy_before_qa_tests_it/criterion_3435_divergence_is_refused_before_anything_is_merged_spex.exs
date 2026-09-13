defmodule CodeMySpecSpex.Story1046.Criterion3435Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3435 — Divergence is refused before anything is merged.

  Rule: Whether a merge can succeed is decided before it is attempted, and
  refused plainly when it cannot.

  ## Why this criterion exists

  John, 2026-09-12, after a promotion held the project's lock for 45 minutes and
  had to be cleared by restarting the shared dev server: "the merge needs to
  happen immediately — we can know if the merge will succeed, and we need to
  immediately merge and then start the deployment async after that. This friction
  is unacceptable."

  "We can know if the merge will succeed" is the load-bearing half. It is what
  makes an immediate, unconditional merge safe rather than reckless: the
  precondition is checked first, so by the time the merge runs there is nothing
  left for it to discover. Refusing earlier is what buys the merge being
  unconditional — the opposite of a corner cut.

  ## What is asserted, and what would pass falsely

  Two things, and the second is the one a partial implementation satisfies.

  A refusal is easy. A refusal *that left the target alone* is the claim: an
  implementation that attempts the merge, hits a conflict, aborts, and then
  reports a refusal also produces a refusal — while having touched the shared
  checkout every other project on the machine is reading. So this asserts the
  running copy's HEAD is exactly where it was, and that no merge is in progress.

  `MERGE_HEAD` is checked rather than inferred from the log, because an aborted
  merge and a merge never attempted have the same history and differ only in
  what was left behind.
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

  spex "A branch that does not contain main is refused before the merge" do
    scenario "somebody else's commit landed on main while this agent worked" do
      given_ "a story branch with work on it", context do
        context = a_promotable_project(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        {:ok, context}
      end

      given_ "and a commit on main the branch does not have", context do
        write(context.running_root, "lib/broken_oaths/diplomacy/treaty.ex", treaty())
        {_, 0} = git(context, context.running_root, ["add", "-A"])

        {_, 0} =
          git(context, context.running_root, ["commit", "-q", "-m", "somebody else's work"])

        # The premise, stated rather than assumed: this is divergence, not a
        # branch that is merely behind. Both sides have something the other
        # does not, which is the case a fast-forward cannot serve.
        {out, 0} =
          git(context, context.agent_root, [
            "rev-list",
            "--left-right",
            "--count",
            "main...story/war"
          ])

        [behind, ahead] =
          out |> String.trim() |> String.split(~r/\s+/) |> Enum.map(&String.to_integer/1)

        assert behind > 0 and ahead > 0,
               "the premise failed: this is not divergence (#{behind} behind, #{ahead} ahead)"

        {:ok, Map.put(context, :head_before, head_of(context, context.running_root))}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context))}
      end

      then_ "it is refused, and told to merge main into its own branch", context do
        text = response_text(context.response)

        assert context.response.isError,
               """
               A diverged branch was promoted rather than refused. The merge is
               unconditional precisely because this check ran first; without it,
               the merge is the thing that discovers the problem — on the shared
               checkout, after it has already started. Got: #{text}
               """

        assert text =~ "merge" and text =~ "main",
               """
               The refusal does not name the remedy. Divergence is ordinary on a
               shared checkout — somebody else promoting while you worked — so
               this string is read constantly and has to say what to do rather
               than only what is wrong. Got: #{text}
               """

        {:ok, context}
      end

      and_ "the running copy was not touched", context do
        assert head_of(context, context.running_root) == context.head_before,
               """
               The running copy's HEAD moved on a promotion that was refused.
               Every other project on this machine reads that checkout.
               """

        refute exists?(context.running_root, ".git/MERGE_HEAD"),
               """
               A merge was attempted and left in progress on the shared checkout.
               A refusal that aborts a merge it should never have started looks
               identical to this one from the caller's side, and differs entirely
               for whoever works in that checkout next — which is why this is
               asserted on MERGE_HEAD rather than on the history, where an
               aborted merge and a merge never attempted are indistinguishable.
               """

        refute exists?(context.running_root, ".restarted"),
               "a refused promotion restarted the application"

        {:ok, context}
      end
    end
  end
end
