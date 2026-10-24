defmodule CodeMySpecSpex.Story1046.Criterion3173Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3173 — There is one place work goes.

  Rule: The running dev copy sits on main; a promotion has exactly one merge
  target.

  John's branch-topology call, made when the alternative was a per-copy
  integration branch: the running dev copy sits on main and everything merges
  there. One target, chosen by the project's designation rather than by the
  promoting agent.

  So the tool takes no branch. An agent that could name its target could name
  the wrong one, and "which branch is the app actually running?" becomes a
  question with two answers — the same shape as the preview-URL rule that
  `record_preview_url/2` refuses on a non-main copy.

  `promote` now takes a story number (e1174640), but that names *what is
  being latched*, not where the merge goes — the merge target is still main,
  unconditionally, and still not something the caller can choose. The rule
  this criterion guards is unchanged; only the tool's other parameter grew.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.Fixtures.StoryIssueBag
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A promotion has exactly one target, and does not take one", criterion: 1180 do
    scenario "a third checkout exists and the work does not go there" do
      given_ "a story branch with committed work", context do
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

      given_ "a third checkout that is not the running one", context do
        elsewhere = CodeMySpec.TempFile.dir("spex-1046-elsewhere")
        {_, 0} = ExecutionContexts.cmd(context.execution_context, "rm", ["-rf", elsewhere])

        {_, 0} =
          git(context, context.running_root, [
            "worktree",
            "add",
            "-b",
            "somewhere-else",
            elsewhere,
            "main"
          ])

        _ =
          CodeMySpecSpex.PromotionHelpers.join_local_working_copy(
            context,
            elsewhere,
            "somewhere else entirely"
          )

        {:ok, Map.put(context, :elsewhere, elsewhere)}
      end

      given_ "main has independent work and both copies' analyzers are current", context do
        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes, naming no target", context do
        response = promote(context, context.story.number)
        refute response.isError, response_text(response)
        the_gate_answers(context)
        told = what_the_agent_was_told(context)
        assert told =~ "landed on main", told
        {:ok, context |> Map.put(:response, response) |> Map.put(:told, told)}
      end

      then_ "the work is on the designated running copy", context do
        merged = read(context.running_root, "lib/broken_oaths/diplomacy/war.ex")

        assert merged =~ ":from_the_copy",
               "the work did not reach the copy the application runs from"

        {:ok, context}
      end

      then_ "and the other checkout was left alone", context do
        {log, 0} = git(context, context.elsewhere, ["log", "--oneline", "-1"])

        assert log =~ "base",
               "work reached a checkout that is not the one the app runs from. " <>
                 "Got: #{log}"

        {:ok, context}
      end
    end
  end
end
