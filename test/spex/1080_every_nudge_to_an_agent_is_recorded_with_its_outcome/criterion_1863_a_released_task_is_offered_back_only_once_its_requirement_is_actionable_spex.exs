defmodule CodeMySpecSpex.Story1080.Criterion1863Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1863 — A released task is offered back for resuming only once its
  requirement is actionable; until then the agent is told its blocker cleared
  and what the task still waits on.

  Offer 0c828c03: the QA agent was told "resume task 2e2791df with start_task"
  while `qa_complete` still waited on implementation work, read
  `get_next_requirement`, found it blocked, and ended its turn — scored as
  ignoring an offer it could not take.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.IdleAgentHelpers, only: [heard: 2]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.ReadyForQaHelpers, only: [add_criterion: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A released task that still waits is not offered back", criterion: 1863 do
    scenario "the question is answered after the story gained a criterion with no spec" do
      given_ "a coder blocked its ready_for_qa task on a question", context do
        context = coder_holding_a_task(context)

        params = %{
          questions: [%{"question" => "Which way?", "options" => [%{"label" => "Left"}]}]
        }

        reply =
          ToolLibrary.run(
            "ask_user_question",
            params,
            Map.put(
              agent_frame(context, context.coder).assigns,
              :scope,
              agent_frame(context, context.coder).assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, reply), response_text(reply)
        {:ok, Map.put(context, :question, Fixtures.question_id_from(response_text(reply)))}
      end

      given_ "the story gained a criterion that has no spec yet", context do
        reply = add_criterion(context, context.story, "A booking can be cancelled")
        refute reply.isError, response_text(reply)
        {:ok, context}
      end

      when_ "the user answers the question", context do
        :ok = user_answers(context, context.question, "Left")
        {:ok, context}
      end

      then_ "the agent is not offered the task", context do
        id = context.coder

        refute_receive {:work_turn_requested, ^id, _ref, "Your blocker" <> _},
                       1_000,
                       "a task that still waits was offered back for resuming"

        assert [] =
                 context
                 |> offers(context.coder, %{kind: "unblocked"})
                 |> Enum.filter(&(&1.status == "open")),
               listing(context)

        {:ok, context}
      end

      then_ "and is told its blocker cleared and what the task waits on", context do
        told = context |> heard(context.coder) |> Enum.join("\n")
        assert told =~ "is not ready to resume: it waits on", told
        assert told =~ "Do not start it yet", told
        {:ok, context}
      end
    end
  end
end
