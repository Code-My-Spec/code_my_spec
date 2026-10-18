defmodule CodeMySpecSpex.Story1080.Criterion1799Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1799 — Releasing a blocked task or denying a tap-out records an
  unblocked offer, linked to the resume prompt, never as a second active task.

  Both put an agent back on a task it had stopped on and tell it to resume it
  — after any turn the agent already has in flight, not racing it with a
  second one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Releasing a question-blocked task is an unblocked offer", criterion: 1799 do
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

      then_ "exactly one unblocked offer on the task, linked to the resume prompt", context do
        assert_offer(context, "unblocked", "task:#{context.task_id}")
      end

      then_ "the task is not also offered as a second active task", context do
        # The unblocked offer is the release -- the task itself stays :blocked
        # until the agent resumes it with start_task, so nothing here reads
        # as active yet. "Never as a second active task" means no duplicate
        # was created, which an empty list already shows.
        assert active_task_ids(context) == []
        {:ok, context}
      end
    end
  end

  # Product's correction on bed5e0d7 (rewriting 1799's own text): "unblocked"
  # in the one-line criterion was loose wording, not a requirement that a
  # denied tap-out share the unblocked kind. Releasing a blocked task is one
  # unblocked offer; denying a tap-out is one denial offer, whose prompt
  # tells the agent its tap-out was declined and to resume (criterion 1869
  # depends on that, and the denial kind's own one-rung ladder stays).
  spex "Denying a tap-out records exactly one denial offer", criterion: 1799 do
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

      then_ "exactly one denial offer on the task, linked to the resume prompt", context do
        assert_offer(context, "denial", "task:#{context.task_id}")
      end

      then_ "the task is not also offered as a second active task", context do
        assert active_task_ids(context) == []
        {:ok, context}
      end
    end
  end

  defp turn_prompt(context) do
    id = context.coder
    assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
    prompt
  end

  defp frame(context) do
    %Frame{assigns: %{current_scope: context.scope, agent_id: context.coder}}
  end

  defp assert_offer(context, kind, subject) do
    assert context.sent =~ "resume task #{context.task_id}",
           "the agent was not told to resume its task: #{context.sent}"

    recorded = offers(context, context.coder, %{kind: kind})

    assert Enum.any?(recorded, &(excerpt(context.sent) in &1.messages)),
           "the turn the agent got is not recorded as a #{kind} offer:\n" <> listing(context)

    assert Enum.all?(recorded, &(&1.subject == subject)), listing(context)
    assert [_one] = Enum.filter(recorded, &(&1.status == "open")), listing(context)
    {:ok, context}
  end

  defp active_task_ids(context) do
    {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, frame(context))

    ~r/`([0-9a-f-]{36})`/
    |> Regex.scan(response_text(tasks), capture: :all_but_first)
    |> List.flatten()
  end
end
