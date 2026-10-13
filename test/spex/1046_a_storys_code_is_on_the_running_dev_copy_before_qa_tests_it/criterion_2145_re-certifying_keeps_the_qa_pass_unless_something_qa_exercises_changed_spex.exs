defmodule CodeMySpecSpex.Story1046.Criterion2145Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 2145 — Re-certifying after a change that touches nothing QA
  exercises keeps the QA pass; a product change needs QA again.

  Rule (John, 2026-10-11, "product changes only"): QA exercises the running app
  and what builds it — `lib/`, `assets/`, `priv/`, `config/`, `rel/`, `mix.exs`,
  `mix.lock`. A test, spex or doc commit after QA re-certifies without another
  hour of QA; a change to the app does not.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  import CodeMySpecSpex.ReadyForQaHelpers,
    only: [a_held_ready_for_qa_task: 2, complete_ready_for_qa: 1]

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A test-only change re-certifies without another QA pass", criterion: 2145 do
    scenario "the team adds a test after QA passed, then re-certifies" do
      given_ "a story QA passed, then a commit touching only tests", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context)

        commit_work(
          context,
          context.agent_root,
          "test/broken_oaths/diplomacy/war_test.exs",
          "defmodule BrokenOaths.Diplomacy.WarTest do\nend\n"
        )

        context = analyzers_are_current(context)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      when_ "the agent completes ready_for_qa, then promotes", context do
        {error?, text} = complete_ready_for_qa(context)
        refute error?, text
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "the promote is queued on the pass QA already gave", context do
        text = response_text(context.response)
        refute context.response.isError, text
        assert text =~ "Queued for promotion", text
        {:ok, context}
      end
    end
  end

  spex "A product change needs QA again", criterion: 2145 do
    scenario "the team changes the app after QA passed, then re-certifies" do
      given_ "a story QA passed, then a commit changing lib/", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context)

        commit_work(
          context,
          context.agent_root,
          "lib/broken_oaths/diplomacy/war.ex",
          war(":changed")
        )

        context = analyzers_are_current(context)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      when_ "the agent completes ready_for_qa, then promotes", context do
        {error?, text} = complete_ready_for_qa(context)
        refute error?, text
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "the promote is refused until QA passes it again", context do
        text = response_text(context.response)
        assert context.response.isError, text
        assert text =~ "has not passed QA", text
        {:ok, context}
      end
    end
  end
end
