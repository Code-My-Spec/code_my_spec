defmodule CodeMySpecSpex.Story1046.Criterion3174Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3174 — Uncommitted work is refused before the merge is attempted.

  Rule: A working copy with uncommitted changes promotes nothing.

  John asked for this directly: "I think we want a tool that refuses a dirty
  tree." A merge from a copy with unstaged work either drags it along or loses
  it, and both are worse than a refusal the agent can act on — it has a commit
  to make, and it knows how.

  Refused *before* the merge rather than cleaned up after: an aborted half-merge
  leaves the running checkout in a state nobody asked for, and the agent then
  has two problems instead of one.
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

  spex "A dirty tree is refused before anything is merged", criterion: 1181 do
    scenario "the agent has written files it has not committed" do
      given_ "a story branch with uncommitted work on it", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":uncommitted"))

        {out, 0} = git(context, context.agent_root, ["status", "--porcelain"])

        assert out =~ "war.ex",
               "the premise failed: the agent's tree is not dirty, so this " <>
                 "would pass against a tool that never looks"

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

      when_ "the agent tries to promote", context do
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "nothing is merged", context do
        assert context.response.isError,
               "a copy with uncommitted work reported a completed promotion"

        {head, 0} = git(context, context.running_root, ["log", "--oneline", "-1"])

        assert head =~ "base",
               "the running checkout moved despite the refusal. Got: #{head}"

        {:ok, context}
      end

      then_ "the agent is told to commit", context do
        assert response_text(context.response) =~ ~r/commit|uncommitted|dirty/i,
               "the refusal did not say what was wrong, and committing is the " <>
                 "one thing the agent could have done about it"

        {:ok, context}
      end
    end
  end
end
