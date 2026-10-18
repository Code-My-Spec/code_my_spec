defmodule CodeMySpecSpex.Story1015.Criterion2390Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2390 — Live classes yield one directive and a tally of the rest.

  The rule:

  > The hook names exactly one class as next and tallies every other live class.

  This is the shape John chose over the two alternatives, and the reasons are
  worth keeping because they are what the assertions encode. A strict single
  directive is cheapest to act on but lets a lower-priority class starve
  invisibly — you never learn it exists. A full menu on every stop hides the
  important item in a wall of text and invites the agent to take the easiest
  rather than the most important. One directive plus a tally is the pair: act on
  one thing, know what else is waiting.

  So both halves are load-bearing and both are asserted. A response naming one
  class and nothing else satisfies the first assertion and fails the second,
  which is the strict-directive failure mode. A response listing everything
  equally fails the first, which is the full-menu one.

  ## The situation this reproduces

  Both classes live at once — an unfinished task and unsatisfied requirements.
  Problems were a class until 2026-10-18, when they stopped blocking a stop and
  became a line of information; issues stopped being one on 2026-09-05.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`, with an unfinished
  implementation task, the refusal a stop has now that problems never block.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.HarnessHooks

  @calls ~w(evaluate_task get_next_requirement)

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One class is named as next and the rest are tallied", criterion: 891 do
    scenario "an unfinished task and requirements are both live" do
      given_ :synced_context_component
      given_ :unfinished_implementation_task_started

      given_ "the agent has asked for its next requirement, so the graph is computed",
             context do
        # Kept even though requirements no longer appear in the tally, because it
        # is what proves they cannot. The menu reads the *cached* actionable set
        # and omits the class on a miss — computing it globs the working copy,
        # and the stop decision runs inside the channel process for a
        # harness-served project.
        #
        # This warms the cache through the real tool, and the class is still
        # absent below: the stop hook syncs files and records problems before it
        # decides, and `GraphFingerprint.compute/2` hashes both, so the entry
        # warmed here is stale by the time the menu renders. On any stop that
        # follows work — nearly all of them — requirements is unknowable without
        # the recompute that deadlocks.
        response =
          ToolLibrary.run("get_next_requirement", %{}, %{scope: context.scope})

        assert match?({:ok, _}, response),
               "the graph must compute for requirements to be a live class at all"

        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "exactly one class is named as next, with its call", context do
        reason = context.response["reason"] || ""
        named = Enum.filter(@calls, &String.contains?(directive(reason), &1))

        assert length(named) == 1,
               "a stop with two classes live must point at one of them. Naming none " <>
                 "leaves the agent to guess; naming both is the menu that hides the " <>
                 "important item in the easy ones. Named: #{inspect(named)}. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the other live classes are tallied with counts", context do
        reason = context.response["reason"] || ""

        # Requirements rather than issues. Issues stopped being a menu class on
        # 2026-09-05: the graph already carries them as `issues_triaged`
        # (product's) and `issues_resolved` (coding's), counted against
        # `fix_issues_min_severity`, so a class beside them was the same work
        # counted twice by the cruder accounting — no role, no threshold, and
        # ranked above the graph's own answer.
        assert reason =~ ~r/\d+\s+requirements?\b/i,
               "a live class that is not the directive must appear in the tally " <>
                 "with a count — otherwise it starves invisibly, which is the " <>
                 "failure a strict single directive has. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  # The line offering the next action, if there is one. Isolated so that a call
  # name appearing incidentally elsewhere in the response — in the tally, or in
  # the harness-friction footer — is not mistaken for a directive.
  defp directive(reason) do
    reason
    |> String.split("\n")
    |> Enum.find("", &(&1 =~ ~r/\bnext\b/i))
  end
end
