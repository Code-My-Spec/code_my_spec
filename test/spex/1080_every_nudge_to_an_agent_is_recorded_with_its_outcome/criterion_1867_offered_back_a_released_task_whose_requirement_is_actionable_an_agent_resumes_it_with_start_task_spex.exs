defmodule CodeMySpecSpex.Story1080.Criterion1867Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1867 — Offered back a released task whose requirement is
  actionable, an agent resumes it with start_task within that turn.

  `Work.resume_ready/4` names the exact call: "resume task <id> with
  `start_task(...)`."
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A released, actionable task is resumed with start_task in the same turn", criterion: 1867 do
    scenario "a coder's blocking question is answered" do
      given_ "a coder holding a task blocked it on a question", context do
        context = coder_holding_a_task(context)
        task_id = context.task_id

        {:reply, reply, _} =
          CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [
                %{"question" => "Which way?", "options" => [%{"label" => "Left"}]}
              ]
            },
            agent_frame(context, context.coder)
          )

        refute reply.isError, response_text(reply)
        {:ok, Map.put(context, :blocker, Fixtures.question_id_from(response_text(reply)))}
      end

      when_ "the question is answered and the agent calls start_task on the named task", context do
        :ok = user_answers(context, context.blocker, "Left")
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
        assert prompt =~ "resume task #{context.task_id}", prompt

        {:reply, resumed, _} =
          StartTask.execute(
            %{requirement_name: "ready_for_qa", entity_type: "story", entity_id: context.task_id},
            agent_frame(context, context.coder)
          )

        {:ok, Map.merge(context, %{prompt: prompt, resumed: resumed})}
      end

      then_ "it resumes the same task, within that turn", context do
        refute context.resumed.isError, response_text(context.resumed)

        {:reply, tasks, _} =
          ListTasks.execute(%{status: "active"}, agent_frame(context, context.coder))

        refute tasks.isError, response_text(tasks)

        assert response_text(tasks) =~ context.task_id,
               "the task did not resume:\n" <> response_text(tasks)

        {:ok, context}
      end

      then_ "and the unblocked offer that carried the instruction is accepted", context do
        assert [%{status: "claimed"} | _] = offers(context, context.coder, %{kind: "unblocked"}),
               listing(context)

        {:ok, context}
      end
    end
  end
end
