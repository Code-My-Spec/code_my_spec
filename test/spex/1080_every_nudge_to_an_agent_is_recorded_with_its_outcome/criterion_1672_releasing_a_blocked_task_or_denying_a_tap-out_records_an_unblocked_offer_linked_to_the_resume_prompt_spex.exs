defmodule CodeMySpecSpex.Story1080.Criterion1672Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1672 — Releasing a blocked task records an unblocked offer linked to
  the resume prompt; denying a tap-out records a denial offer.

  Both put an agent back on a task it had stopped on and tell it to resume it.
  A release is offered on the task (claimed by starting it, criterion 1862); a
  denial is its own kind, claimed by taking any work.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
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

        reply =
          ToolLibrary.run(
            "ask_user_question",
            params,
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, reply), response_text(reply)
        {:ok, Map.put(context, :blocker, Fixtures.question_id_from(response_text(reply)))}
      end

      when_ "the user answers it", context do
        :ok = user_answers(context, context.blocker, "Left")
        {:ok, Map.put(context, :sent, turn_prompt(context))}
      end

      then_ "an unblocked offer on the task, linked to the resume prompt", context do
        assert_offer(context, "unblocked", "task:#{context.task_id}")
      end
    end
  end

  spex "Being let back onto a task after a tap-out is recorded as a denial offer",
    criterion: 1672 do
    scenario "main denies a task's tap-out" do
      given_ "a continuous coder asked to tap out of its task", context do
        context = coder_holding_a_task(context)

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.coder}}

        reply =
          ToolLibrary.run(
            "tap_out",
            %{task_id: context.task_id, reason: "This is not mine to do."},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, reply), response_text(reply)
        [_, request_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(reply))
        {:ok, Map.put(context, :blocker, request_id)}
      end

      when_ "main denies it", context do
        {:reply, reply, _} =
          AnswerNotification.execute(
            %{
              notification_id: context.blocker,
              decision: "deny",
              answer: "It is yours: carry on."
            },
            frame(context)
          )

        refute reply.isError, response_text(reply)
        {:ok, Map.put(context, :sent, turn_prompt(context))}
      end

      then_ "a denial offer on that tap-out, linked to the resume prompt", context do
        assert_offer(context, "denial", "tap_out:#{context.blocker}")
      end
    end
  end

  defp turn_prompt(context) do
    id = context.coder
    assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
    prompt
  end

  defp assert_offer(context, kind, subject) do
    assert context.sent =~ "resume task #{context.task_id}",
           "the agent was not told to resume its task: #{context.sent}"

    # The release and the graph change it causes can both tell the agent; the
    # second is linked to the offer already standing, so exactly one stands.
    recorded = offers(context, context.coder, %{kind: kind})

    assert Enum.any?(recorded, &(excerpt(context.sent) in &1.messages)),
           "the turn the agent got is not recorded as a #{kind} offer:\n" <> listing(context)

    assert Enum.all?(recorded, &(&1.subject == subject)), listing(context)
    assert [_one] = Enum.filter(recorded, &(&1.status == "open")), listing(context)
    {:ok, context}
  end
end
