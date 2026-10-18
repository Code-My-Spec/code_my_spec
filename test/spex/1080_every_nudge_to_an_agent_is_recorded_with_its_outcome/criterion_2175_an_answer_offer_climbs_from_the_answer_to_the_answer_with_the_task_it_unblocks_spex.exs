defmodule CodeMySpecSpex.Story1080.Criterion2175Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2175 — An answer offer climbs from the answer, to the answer
  with the task it unblocks.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
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

  spex "An answer offer's rungs climb from the answer to the answer with its task",
       criterion: 2175 do
    scenario "the coder ignores the first delivery of the answer" do
      given_ "a coder blocked a held task on a question", context do
        context = coder_holding_a_task(context)

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

      when_ "the answer is delivered, and the coder ignores it", context do
        :ok = user_answers(context, context.blocker, "Left")
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, first}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, Map.put(context, :first, first)}
      end

      then_ "the first rung delivers the answer", context do
        assert context.first =~ "Left", context.first
        {:ok, context}
      end

      then_ "the next rung repeats the answer with the task it unblocks", context do
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, second}, 2_000
        assert second =~ "Left", second
        assert second =~ context.task_id, second
        {:ok, context}
      end
    end
  end
end
