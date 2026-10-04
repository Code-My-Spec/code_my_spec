defmodule CodeMySpecSpex.Story1046.CriterionNewEachRequesterIsToldSpex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion NEW — Each requester is told its own candidate's outcome.

  Rule: the agent that promoted a candidate is told what became of that
  candidate, and only of that one — landed, or taken out and why.
  """

  use CodeMySpecSpex.Case

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

  spex "Each requester is told its own candidate's outcome" do
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

        analyzers_are_current(context)

        {:ok, Map.put(context, :story, a_promotable_story(context))}
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
end
