defmodule CodeMySpecSpex.Story1080.Criterion1672Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1672 — Releasing a blocked task or denying a tap-out records an
  unblocked offer linked to the resume prompt.

  Both put an agent back on a task it had stopped on, and both tell it to
  resume that task. The offer is on what blocked it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "Being let back onto a task is recorded as an unblocked offer", criterion: 1672 do
    scenario "the question that blocked a task is answered" do
      given_ "a continuous coder blocked its task on a question", context do
        context = coder_holding_a_task(context)

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.coder}}

        params = %{
          questions: [
            %{
              "question" => "Which way?",
              "options" => [%{"label" => "Left"}, %{"label" => "Right"}]
            }
          ]
        }

        {:reply, reply, _} = AskUserQuestion.execute(params, frame)
        refute reply.isError, response_text(reply)
        {:ok, Map.put(context, :blocker, Fixtures.question_id_from(response_text(reply)))}
      end

      when_ "the user answers it", context do
        :ok = user_answers(context, context.blocker, "Left")
        {:ok, Map.put(context, :sent, turn_prompt(context))}
      end

      then_ "an unblocked offer on that question, linked to the resume prompt", context do
        assert_unblocked_offer(context)
      end
    end
  end

  spex "Being let back onto a task after a tap-out is recorded as an unblocked offer",
    criterion: 1672 do
    scenario "main denies a task's tap-out" do
      given_ "a continuous coder asked to tap out of its task", context do
        context = coder_holding_a_task(context)

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.coder}}

        {:reply, reply, _} =
          TapOut.execute(%{task_id: context.task_id, reason: "This is not mine to do."}, frame)

        refute reply.isError, response_text(reply)
        [_, request_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(reply))
        {:ok, Map.put(context, :blocker, request_id)}
      end

      when_ "main denies it", context do
        {:reply, reply, _} =
          AnswerNotification.execute(
            %{id: context.blocker, decision: "deny", answer: "It is yours: carry on."},
            frame(context)
          )

        refute reply.isError, response_text(reply)
        {:ok, Map.put(context, :sent, turn_prompt(context))}
      end

      then_ "an unblocked offer on that tap-out, linked to the resume prompt", context do
        assert_unblocked_offer(context)
      end
    end
  end

  defp turn_prompt(context) do
    id = context.coder
    assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
    prompt
  end

  defp assert_unblocked_offer(context) do
    assert context.sent =~ "resume task #{context.task_id}",
           "the agent was not told to resume its task: #{context.sent}"

    assert [offer] = offers(context, context.coder, %{kind: "unblocked"}),
           "expected one unblocked offer:\n" <> listing(context)

    assert offer.subject == "blocker:#{context.blocker}"
    assert offer.messages == [excerpt(context.sent)]
    {:ok, context}
  end
end
