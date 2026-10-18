defmodule CodeMySpecSpex.Story1080.Criterion2176Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2176 — A menu offer climbs from the held tasks, to the first in
  detail.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1, start_session: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.TaskResponseHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A menu offer's rungs climb from the held tasks to the first in detail", criterion: 2176 do
    scenario "a coder holds two tasks and ignores the first rung of the menu" do
      given_ "a coder holding two tasks: one blocked on a question, the next it took", context do
        context =
          context
          |> coding_work_waiting()
          |> FullSatisfactionFixtures.apply_two_components_to_implement()
          |> start_session()
          |> put_to_work()

        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        frame = agent_frame(context, coder.id)

        {:reply, first, _} = StartTask.execute(next_task(context, coder.id), frame)
        refute first.isError, TaskResponseHelpers.response_text(first)
        task_id = TaskResponseHelpers.extract_task_id!(first)

        # One active task at a time: the first is held blocked on a question
        # while the coder takes the other beside it.
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [%{"question" => "Which way?", "options" => [%{"label" => "Left"}]}]
            },
            frame
          )

        refute asked.isError, TaskResponseHelpers.response_text(asked)

        {:reply, second, _} = StartTask.execute(next_task(context, coder.id), frame)
        refute second.isError, TaskResponseHelpers.response_text(second)
        other_task_id = TaskResponseHelpers.extract_task_id!(second)

        {:ok,
         Map.merge(context, %{coder: coder.id, task_id: task_id, other_task_id: other_task_id})}
      end

      when_ "its turn ends, and it ignores the first rung of the menu", context do
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        id = context.coder
        assert_receive {:agent_dispatch, ^id, _ref, first}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, Map.put(context, :first, first)}
      end

      then_ "the first rung lists the held tasks", context do
        assert context.first =~ context.task_id, context.first
        assert context.first =~ context.other_task_id, context.first
        {:ok, context}
      end

      then_ "the next rung gives the detail of the first held task", context do
        id = context.coder
        assert_receive {:agent_dispatch, ^id, _ref, second}, 2_000
        # The menu names every held task each time; the detail is what is new.
        refute context.first =~ "in detail: task", context.first
        assert second =~ "in detail: task #{context.task_id}", second
        {:ok, context}
      end
    end
  end
end
