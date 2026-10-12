defmodule CodeMySpecSpex.Story1046.Criterion2144Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 2144 — A copy reporting a HEAD past its story's certified commit
  releases the certification, so ready_for_qa is offered again.

  The harness reports its copy's HEAD on every sync and at every agent turn
  end. A branch that moved on is not ready for QA, and the graph says so as
  soon as it hears, rather than when a promote is refused.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers, only: [story_requirements: 2, satisfied?: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Phoenix.ChannelTest

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A HEAD past the certified commit releases the certification", criterion: 2144 do
    scenario "the team commits again after its story was certified" do
      given_ "a story assigned to the copy, certified, then another commit", context do
        context = a_promotable_project(context, agent_socket: true)
        story = a_promotable_story(context, assigned?: true)

        commit_work(
          context,
          context.agent_root,
          "lib/broken_oaths/diplomacy/war.ex",
          war(":later")
        )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the copy's harness reports its HEAD", context do
        report_head(context)
        {:ok, context}
      end

      then_ "the story is offered ready_for_qa again", context do
        body = story_requirements(context, context.story)

        refute satisfied?(body, "ready_for_qa"),
               "the certification outlived the commit it was for:\n#{body}"

        {:ok, context}
      end
    end
  end

  spex "The certified HEAD keeps its certification", criterion: 2144 do
    scenario "the copy reports the commit its story was certified at" do
      given_ "a story assigned to the copy and certified at its HEAD", context do
        context = a_promotable_project(context, agent_socket: true)
        story = a_promotable_story(context, assigned?: true)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the copy's harness reports its HEAD", context do
        report_head(context)
        {:ok, context}
      end

      then_ "the story stays ready for QA", context do
        body = story_requirements(context, context.story)
        assert satisfied?(body, "ready_for_qa"), body
        {:ok, context}
      end
    end
  end

  defp report_head(context) do
    head = head_of(context, context.agent_root)
    ref = ChannelTest.push(context.agent_socket, "head_commit", %{"sha" => head})
    ChannelTest.assert_reply(ref, :ok, _, 5_000)
  end
end
