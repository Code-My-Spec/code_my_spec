defmodule CodeMySpecSpex.Story1046.Criterion3434Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3434 — A slow deployment does not become a slow promotion.

  Rule: Promotion answers when the merge has landed, not when deployment has
  finished.

  ## Causal, not timed

  The obvious way to test this is a stopwatch, and it is the wrong one: on a box
  that has spent the evening between two and three and a half times its core
  count, any wall-clock bound is a flake generator rather than a check.

  So the restart recipe here sleeps for a minute before recording anything, and
  the assertion is that the promotion answered *while that was still going* —
  the marker file cannot exist yet. That is the same claim without a clock: an
  implementation that waited could not have returned, because the thing it would
  have waited for has not happened.

  ## Why a minute

  Long enough that the margin is not in question at any load this machine
  reaches, and the test still finishes immediately — nothing waits for the sleep,
  which is the whole point. The detached restart outlives the scenario and is
  cleaned up with the temp directory.
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

  spex "A deployment that takes a minute still answers at once" do
    scenario "the restart recipe is slow" do
      given_ "a story branch with work on it", context do
        context = a_promotable_project(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        {:ok, context}
      end

      given_ "whose restart takes a minute before it records anything", context do
        # Written, not committed. The recipe is read from the working tree, and
        # committing it here would put a commit on main that the story branch
        # does not have — which the fast-forward precondition correctly refuses,
        # testing criterion 3435 instead of this one. Changing the running copy
        # after branching is divergence, whoever does it and for whatever reason.
        write(context.running_root, "justfile", """
        restart:
            @sleep 60
            @date > {{justfile_directory()}}/.restarted
        """)

        refute exists?(context.running_root, ".restarted"),
               "the premise failed: the marker is already there before anything ran"

        {:ok, context}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context))}
      end

      then_ "it is answered before the deployment has finished", context do
        text = response_text(context.response)

        refute context.response.isError,
               "the promotion was refused: #{text}"

        refute exists?(context.running_root, ".restarted"),
               """
               The promotion did not answer until the restart had finished — the
               marker its recipe writes at the end already exists, and that recipe
               sleeps for a minute first. A deployment's duration has become the
               agent's waiting time, which is the whole of what this criterion
               forbids.
               """

        assert text =~ "Merged into",
               "the reply does not report the merge that did land: #{text}"

        {:ok, context}
      end
    end
  end
end
