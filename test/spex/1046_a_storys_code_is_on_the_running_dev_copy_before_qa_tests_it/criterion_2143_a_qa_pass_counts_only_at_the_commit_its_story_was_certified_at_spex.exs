defmodule CodeMySpecSpex.Story1046.Criterion2143Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 2143 — A QA pass counts only at the commit its story was certified
  at: a promote at another commit is refused and the certification released.

  Rule (John, 2026-10-11): certified means at a commit, and promotion asks at
  the candidate. Story 1091 passed QA at one commit, two more commits followed,
  and the queue refused it at landing on every retry while the graph went on
  reporting it done.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers, only: [story_requirements: 2, satisfied?: 2]

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A promote at a commit QA did not certify is refused", criterion: 2143 do
    scenario "the branch moved on after its story passed QA" do
      given_ "a story certified and QA'd, then another commit on its branch", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context)
        certified = head_of(context, context.agent_root)

        commit_work(
          context,
          context.agent_root,
          "lib/broken_oaths/diplomacy/war.ex",
          war(":later")
        )

        context = analyzers_are_current(context)

        {:ok, Map.merge(context, %{story: story, certified: certified})}
      end

      when_ "the agent promotes the story", context do
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "it is refused, naming the certified commit and the copy's HEAD", context do
        text = response_text(context.response)
        head = head_of(context, context.agent_root)

        assert context.response.isError, text
        assert text =~ "certified at #{context.certified}", text
        assert text =~ "not at this copy's HEAD #{head}", text
        {:ok, context}
      end

      then_ "nothing is merged", context do
        {log, 0} = git(context, context.running_root, ["log", "--oneline", "-1"])
        assert log =~ "base", "the uncertified commit moved main. Got: #{log}"
        {:ok, context}
      end

      then_ "the story is offered ready_for_qa again", context do
        body = story_requirements(context, context.story)

        refute satisfied?(body, "ready_for_qa"),
               "the graph went on reporting a certification its branch moved past:\n#{body}"

        {:ok, context}
      end
    end
  end

  spex "A promote at the certified commit goes ahead", criterion: 2143 do
    scenario "nothing was committed after QA passed" do
      given_ "a story certified and QA'd at the copy's HEAD", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context)
        context = analyzers_are_current(context)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent promotes the story", context do
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "it is queued", context do
        text = response_text(context.response)
        refute context.response.isError, text
        assert text =~ "Queued for promotion", text
        {:ok, context}
      end
    end
  end
end
