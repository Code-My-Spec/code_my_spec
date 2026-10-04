defmodule CodeMySpecSpex.Story1091.CriterionNewEachRequesterHearsItsOwnOutcomeSpex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion NEW — Each requester hears its own outcome, story or issue.

  Rule: the queue tells the agent that promoted a candidate what became of
  that candidate, naming what it promoted — a story, or an issue's fix — and
  nothing of anyone else's.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Each requester hears its own outcome, story or issue" do
    scenario "an issue team's fix and another agent's story both land" do
      given_ "an issue team's QA-passed fix, and another agent's QA-passed story", context do
        context =
          context
          |> a_promotable_project()
          |> another_candidate(:story_agent)
          |> an_issue_assigned_to_the_team()
          |> the_coder_fixes_it("lib/broken_oaths/diplomacy/notify.ex", notify())
          |> qa_passes_it()

        commit_work(
          context,
          context.story_agent.root,
          "lib/broken_oaths/diplomacy/oath.ex",
          oath()
        )

        story = a_promotable_story(context, title: "Oaths are sworn")
        its_analyzers_are_current(context, context.story_agent)

        {:ok, context |> analyzers_are_current() |> Map.put(:story, story)}
      end

      when_ "the coder promotes its fix and the other agent promotes its story", context do
        the_coder_promotes_it(context)
        issue_told = what_was_told(context.coder.id)
        # Behind main now that the fix has landed, so gated with it beneath.
        promote_from(context.story_agent, context.story.number)
        the_gate_answers(context)
        story_told = what_was_told(context.story_agent.agent_id)

        {:ok, context |> Map.put(:issue_told, issue_told) |> Map.put(:story_told, story_told)}
      end

      then_ "the coder hears its issue's fix landed", context do
        assert context.issue_told =~ "the fix for issue #{context.issue_id}", context.issue_told
        assert context.issue_told =~ "landed on main", context.issue_told
        refute context.issue_told =~ "story #{context.story.number}", context.issue_told
        {:ok, context}
      end

      then_ "the other agent hears its story landed", context do
        assert context.story_told =~ "story #{context.story.number}", context.story_told
        assert context.story_told =~ "landed on main", context.story_told
        refute context.story_told =~ context.issue_id, context.story_told
        {:ok, context}
      end

      then_ "neither hears the other's outcome", context do
        coder = context.coder.id
        story_agent = context.story_agent.agent_id
        refute_received {:agent_dispatch, ^coder, _, _}
        refute_received {:agent_dispatch, ^story_agent, _, _}
        {:ok, context}
      end
    end
  end

  defp notify,
    do: "defmodule BrokenOaths.Diplomacy.Notify do\n  def deliver, do: :delivered\nend\n"

  defp oath,
    do: "defmodule BrokenOaths.Diplomacy.Oath do\n  def swear, do: :sworn\nend\n"
end
