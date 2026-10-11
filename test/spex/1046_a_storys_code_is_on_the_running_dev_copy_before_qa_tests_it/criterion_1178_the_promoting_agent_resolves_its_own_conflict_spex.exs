defmodule CodeMySpecSpex.Story1046.Criterion3171Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3171 — A conflict is aborted, not left on the shared checkout.

  Rule: a merge conflict is aborted immediately, and the agent is sent to
  resolve it in the copy it is promoting from.

  Superseded twice over now.

  First (bed1d974): a conflict used to stay in the running checkout,
  reasoning that the agent who wrote one side is the only party holding the
  answer and a clean tree after a refusal has nothing to act on. Measured
  cost of that: a worktree six commits behind main spent 2.5 hours
  converging a spec main had already retired, then wedged the shared dev
  checkout — the one machine QA runs from, with no test suite and no way to
  resolve in place — from 00:28 to 10:40 merging it in unattended. The
  identical branch, merged main-first in the worktree instead, conflicted
  immediately and was resolved in two minutes: the same conflict, but with
  context and a test suite, because it happened somewhere a person could
  see it. That gave the running checkout an abort-on-conflict merge that
  named the conflicting file.

  Second (54aa534c, phase two): `Runner.merge/4` is `--ff-only` now, and
  ff-only never inspects file content — it only checks ancestry, before
  touching a single byte. Any divergence, conflicting or not, refuses at
  that check, instantly, with nothing to abort because nothing was ever
  attempted. So this scenario — a real content conflict — is caught the
  same way a same-file-different-lines divergence is, or a completely
  unrelated-files divergence is: refused for being behind main, not
  merged-then-aborted-and-named.

  Third (promote-queue, 2026-10-04): promotions are queued, and the queue
  merges candidates in its own gate checkout. A conflict there is aborted in
  the gate, never on the running checkout, and the candidate is taken out of
  the queue naming the file — the merge was attempted again, so the file is
  known again. The remedy is unchanged: merge main in your own copy.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.Fixtures.StoryIssueBag
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A conflict is taken out of the queue, and the agent is sent to resolve it locally",
    criterion: 1178 do
    scenario "main and the story branch changed the same line" do
      given_ "a story branch that changed a line", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        story = a_promotable_story(context, qa: :not_passed)

        :ok =
          StoryIssueBag.certify(
            context.scope,
            story.id,
            head_of(context, context.agent_root)
          )

        {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)
        {:ok, Map.put(context, :story, story)}
      end

      given_ "main has since changed the same line", context do
        write(context.running_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_main"))

        {_, 0} =
          git(context, context.running_root, ["commit", "-q", "-am", "somebody else's work"])

        {:ok, context}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        response = promote(context, context.story.number)
        refute response.isError, response_text(response)
        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "the promotion does not complete", context do
        assert context.told =~ "taken out",
               "a conflicted merge was reported as a finished promotion"

        {:ok, context}
      end

      then_ "the agent is told which file conflicts", context do
        text = context.told

        assert text =~ "lib/broken_oaths/diplomacy/war.ex",
               "the conflict was found by a merge, so the file it found is known. Got: #{text}"

        {:ok, context}
      end

      then_ "the agent is told to resolve it in its own copy, not the running one", context do
        assert context.told =~ "Merge main into your branch",
               "the agent was refused without being told the remedy is its own to run"

        {:ok, context}
      end

      then_ "the running checkout is left exactly as it was", context do
        {out, 0} = git(context, context.running_root, ["status", "--porcelain"])

        assert out == "",
               "an aborted conflict is supposed to leave nothing behind. Got: #{inspect(out)}"

        {:ok, context}
      end
    end
  end
end
