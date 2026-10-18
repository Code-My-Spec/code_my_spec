defmodule CodeMySpecSpex.Story1046.Criterion2017Spex do
  @moduledoc """
  Story 1046 — Promotion lands verified work on the running dev copy.
  Criterion 2017 — A promote task stays open until its batch lands or is
  ejected, and an agent waiting on a queued landing is not treated as idle:
  it is not nudged to act on that task, and the outcome reaches it when it
  lands.

  Rule: `Agents.Work.busy_on?/1` treats a held `story_promoted` task as
  waiting, not busy, for exactly as long as the queue has not yet decided
  its candidate (`PromotionQueue.open_for/3`). The open attempt is the
  queue's, not the agent's, so nothing is sent to the agent about it until
  the queue itself decides.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A queued promote task stays open and silent until the queue decides it",
    criterion: 2017 do
    scenario "a promotion queued behind main's own movement lands after a wait" do
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

      when_ "the agent promotes it, and the queue has not yet decided its candidate", context do
        response = promote(context, context.story.number)
        refute response.isError, response_text(response)

        {:ok, context}
      end

      then_ "the task stays open, and the agent is sent nothing about it while it waits",
            context do
        text = story_promoted(context)

        assert text =~ "[ ] **story_promoted**",
               "a queued promotion's task does not read open while it waits. Got: #{text}"

        agent_id = context.agent_id
        refute_received {:agent_dispatch, ^agent_id, _, _}

        {:ok, context}
      end

      when_ "the gate answers and the candidate lands", context do
        the_gate_answers(context)
        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "the outcome reaches the agent, and the task closes on the landing", context do
        assert context.told =~ "landed on main", context.told

        text = story_promoted(context)

        assert text =~ "[x] **story_promoted**",
               "the landing did not satisfy story_promoted. Got: #{text}"

        {:ok, context}
      end
    end
  end

  defp story_promoted(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    response =
      ToolLibrary.run(
        "list_requirements",
        %{
          entity_type: "story",
          entity_id: to_string(context.story.number),
          requirement_name: "story_promoted"
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    response_text(response)
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"
end
