defmodule CodeMySpecSpex.Story1046.CriterionNewStoryPromotedStaysOpenSpex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion NEW — The story_promoted task stays open until its candidate lands.

  Rule: queueing is not promotion. A story whose candidate is in the queue is
  still unpromoted — `story_promoted` is unsatisfied and its task open — and it
  is satisfied by the landing, which stamps the story.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The story_promoted task stays open until its candidate lands" do
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

        analyzers_are_current(context)

        {:ok, Map.put(context, :story, a_promotable_story(context))}
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
