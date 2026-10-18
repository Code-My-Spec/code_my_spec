defmodule CodeMySpecSpex.Story1046.Criterion2021Spex do
  @moduledoc """
  Story 1046 — Promotion lands verified work on the running dev copy.
  Criterion 2021 — A queued promotion does not consume the agent's task
  slot: an agent whose only open task is a promotion already handed to the
  queue can still claim other work assigned to it, and the promote task
  still closes on the landing rather than being cancelled to free the slot.

  Rule: `start_task` refuses a second claim while an ordinary task is open
  (criterion 1446). A `story_promoted` task held while its candidate is
  still queued is the exception — the open attempt is the queue's, not the
  agent's — so a second claim for other assigned work succeeds, and the
  promote task itself is only ever closed by the landing, never cancelled
  to make room.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.PromotionHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent with a queued promotion can still claim other assigned work",
    criterion: 2021 do
    scenario "the agent claims a second story's work while its promotion waits in the queue" do
      given_ "a queued promotion, and another story for the same agent", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())

        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        story = a_promotable_story(context)
        context = analyzers_are_current(context)

        queued = promote(context, story.number)
        refute queued.isError, response_text(queued)

        other_story =
          StoryHelpers.create_story(context.scope,
            title: "Another story for the same agent",
            description: "As a user, I want this one worked too.",
            acceptance_criteria: ["It works"]
          )

        {:ok, context |> Map.put(:story, story) |> Map.put(:other_story, other_story)}
      end

      when_ "the agent claims the other story's work", context do
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.agent_id}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.other_story.number)
            },
            frame
          )

        {:ok, Map.merge(context, %{response: response, agent_frame: frame})}
      end

      then_ "the claim succeeds rather than being refused for an open task", context do
        refute context.response.isError, response_text(context.response)

        {:reply, tasks, _frame} = ListTasks.execute(%{status: "active"}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "bdd_specs_exist"

        {:ok, context}
      end

      when_ "the queued candidate lands", context do
        the_gate_answers(context)
        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "the promote task closes on the landing, not by being cancelled to free the slot",
            context do
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
