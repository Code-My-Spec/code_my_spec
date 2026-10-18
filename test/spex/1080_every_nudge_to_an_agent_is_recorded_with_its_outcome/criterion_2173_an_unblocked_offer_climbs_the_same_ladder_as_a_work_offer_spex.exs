defmodule CodeMySpecSpex.Story1080.Criterion2173Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2173 — An unblocked offer climbs the same ladder as a work
  offer: id, then detail, then adjacent tasks.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.StoryBoundHelpers, only: [issue_accepted: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "An unblocked offer's rungs climb from id, to detail, to alternatives", criterion: 2173 do
    scenario "a coder ignores its released task three turns running" do
      given_ "a coder holding a task blocked it on a question, with an accepted issue beside it",
             context do
        context = coder_holding_a_task(context)
        context = issue_accepted(context, context.story)

        {:reply, reply, _} =
          AskUserQuestion.execute(
            %{
              task_id: context.task_id,
              questions: [%{"question" => "Which way?", "options" => [%{"label" => "Left"}]}]
            },
            agent_frame(context, context.coder)
          )

        refute reply.isError, response_text(reply)
        {:ok, Map.put(context, :blocker, Fixtures.question_id_from(response_text(reply)))}
      end

      when_ "the question is answered", context do
        :ok = user_answers(context, context.blocker, "Left")
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, first}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :first, first)}
      end

      then_ "the first rung names the task by its id", context do
        assert context.first =~ context.task_id, context.first
        {:ok, context}
      end

      when_ "it ends the turn without resuming, and is offered again", context do
        id = context.coder
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, second}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :second, second)}
      end

      then_ "the next rung sends the task's detail", context do
        assert context.second =~ "Why it matters:", context.second
        {:ok, context}
      end

      when_ "it ignores that too, and is offered a third time", context do
        id = context.coder
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, third}, 2_000
        {:ok, Map.put(context, :third, third)}
      end

      then_ "the next rung also names adjacent tasks it could take instead", context do
        assert context.third =~ "Other work you could take instead:", context.third
        {:ok, context}
      end
    end
  end
end
