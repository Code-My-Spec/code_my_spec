defmodule CodeMySpecSpex.Story983.Criterion8158Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 729 — Promoting a story whose spex are all green on the certifying
  spex run latches it specs-ready; nothing else sets that latch.

  The latch means "promoted with its spex green" (John, 2026-10-02). Certifying
  a story ready for QA stamps a commit on it and leaves this latch alone:
  that is per copy and pre-merge, and must not make the story's red spex block
  other copies' promotions.

  Promotion is queued (2026-10-04): `promote` answers with the candidate's
  place, and the latch is set when the queue lands it — so the scenario waits
  for the agent to be told it landed.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.Fixtures.StoryIssueBag
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The queue gates and lands from its own worker, and tells the agent.
  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp latched?(context, story), do: Stories.get_story(context.scope, story.id).specs_ready

  spex "Promotion latches a green story specs-ready", criterion: 729 do
    scenario "the story's spex are all green on the certifying run" do
      given_ "an agent's copy with the story's spex green and analyzers clean at HEAD",
             context do
        context =
          context
          |> a_promotable_project()
          |> an_agent_on_the_copy()
          |> with_work_on_the_copy()
          |> analyzers_are_current()

        story = a_promotable_story(context, qa: :not_passed)
        commit_work(context, context.agent_root, "WORK.md", "work on story #{story.number}\n")
        context = analyzers_are_current(context)

        :ok = StoryIssueBag.certify(context.scope, story.id, head_of(context, context.agent_root))
        {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the story is promoted, and the queue lands it", context do
        response = promote(context, context.story.number)

        {:ok,
         context
         |> Map.put(:response, response)
         |> Map.put(:told, what_the_agent_was_told(context))}
      end

      then_ "the story is latched specs-ready", context do
        refute context.response.isError, inspect(context.response)
        assert context.told =~ "landed on main", context.told
        assert latched?(context, context.story)
        {:ok, context}
      end
    end
  end

  spex "Certifying for QA does not set the latch", criterion: 729 do
    scenario "the story is certified ready for QA but not promoted" do
      given_ "a coding agent holding the story's ready-for-QA task on a clean copy",
             context do
        context = a_promotable_project(context)
        story = a_promotable_story(context, qa: :not_passed)
        context = analyzers_are_current(context)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      when_ "the agent completes the task", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "the story is stamped ready for QA and not latched", context do
        {error?, text} = context.answer
        refute error?, text
        assert qa_stamp(context, context.story)
        refute latched?(context, context.story)
        {:ok, context}
      end
    end
  end
end
