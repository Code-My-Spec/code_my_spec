defmodule CodeMySpecSpex.Story1046.Criterion1973Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1973 — Each requester hears its own outcome, story or issue.

  Rule: the queue tells the agent that promoted a candidate what became of
  that candidate — landed, or taken out and why — naming what it promoted (a
  story, or an issue's fix), and nothing of anyone else's. The requester's
  promotion task stays open until its candidate lands.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Each requester hears its own outcome, story or issue", criterion: 1973 do
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

        story_context = %{
          context
          | scope: context.story_agent.scope,
            agent_root: context.story_agent.root
        }

        story = a_promotable_story(story_context, title: "Oaths are sworn")
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

  spex "Each requester is told its own candidate's outcome", criterion: 1973 do
    scenario "one agent's candidate lands and another's is taken out" do
      given_ "two agents' branches that change the same line of War", context do
        context =
          context
          |> a_promotable_project()
          |> an_agent_on_the_copy()
          |> another_candidate(:second)

        commit_work(
          context,
          context.agent_root,
          "lib/broken_oaths/diplomacy/war.ex",
          war(":first")
        )

        commit_work(
          context,
          context.second.root,
          "lib/broken_oaths/diplomacy/war.ex",
          war(":second")
        )

        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)

        {:ok, context}
      end

      when_ "both promote, one after the other", context do
        promote(context, context.story.number)
        first = what_the_agent_was_told(context)
        promote_from(context.second, nil)
        second = what_was_told(context.second.agent_id)

        {:ok, context |> Map.put(:first, first) |> Map.put(:second_told, second)}
      end

      then_ "the first agent is told its story landed", context do
        assert context.first =~ "story #{context.story.number}", context.first
        assert context.first =~ "landed on main", context.first
        {:ok, context}
      end

      then_ "the second agent is told its own candidate was taken out", context do
        commit = context |> head_of(context.second.root) |> String.slice(0, 12)
        assert context.second_told =~ commit, context.second_told
        assert context.second_told =~ "taken out of the queue", context.second_told
        refute context.second_told =~ "story #{context.story.number}", context.second_told
        {:ok, context}
      end

      then_ "neither is told the other's outcome", context do
        first_agent = context.agent_id
        second_agent = context.second.agent_id
        refute_received {:agent_dispatch, ^first_agent, _, _}
        refute_received {:agent_dispatch, ^second_agent, _, _}
        {:ok, context}
      end
    end
  end

  spex "The story_promoted task stays open until its candidate lands", criterion: 1973 do
    scenario "a story's candidate waits in the queue, then lands" do
      given_ "a story branch main has moved past", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())

        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)

        {:ok, context}
      end

      when_ "the agent promotes it", context do
        promote(context, context.story.number)
        {:ok, context}
      end

      then_ "the story is not promoted while its candidate is queued", context do
        assert the_gate_is_running(context) == ~w(compiler credo exunit spex)
        text = story_promoted(context)

        assert text =~ "[ ] **story_promoted**",
               "a story whose candidate has not landed reads promoted. Got: #{text}"

        {:ok, context}
      end

      when_ "its candidate is gated clean and lands", context do
        the_gate_answers(context)
        assert what_the_agent_was_told(context) =~ "landed on main"
        {:ok, context}
      end

      then_ "the story is promoted", context do
        text = story_promoted(context)

        assert text =~ "[x] **story_promoted**",
               "the landing did not satisfy story_promoted. Got: #{text}"

        {:ok, context}
      end
    end
  end

  defp notify,
    do: "defmodule BrokenOaths.Diplomacy.Notify do\n  def deliver, do: :delivered\nend\n"

  defp oath,
    do: "defmodule BrokenOaths.Diplomacy.Oath do\n  def swear, do: :sworn\nend\n"

  defp story_promoted(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      ListRequirements.execute(
        %{
          entity_type: "story",
          entity_id: to_string(context.story.number),
          requirement_name: "story_promoted"
        },
        frame
      )

    response_text(response)
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"
end
