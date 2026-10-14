defmodule CodeMySpecSpex.Story1080.Criterion1671Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1671 — Answering a question records an answer offer on that
  question, linked to the message that carried the answer.

  An idle asker gets the answer as a turn; one mid-turn gets it as a message.
  Either way the offer is on the question and points at what carried it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers, only: [start_session: 1]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
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

  spex "An answer is recorded as an offer on its question", criterion: 1671 do
    scenario "an idle continuous agent's question is answered" do
      given_ "a continuous coder that asked a question and ended its turn", context do
        context = start_session(context)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        :ok = Fixtures.agent_said(context.scope, coder, "I need a decision first.")
        question = ask(context, coder)
        {:ok, Map.merge(context, %{coder: coder.id, question: question})}
      end

      when_ "the user answers it", context do
        :ok = user_answers(context, context.question, "Yes")
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
        {:ok, Map.put(context, :sent, prompt)}
      end

      then_ "an answer offer on the question, linked to the turn that carried it", context do
        assert_answer_offer(context)
      end
    end

    scenario "a question is answered while its agent is mid-turn" do
      given_ "a continuous coder that asked a question and is still working", context do
        context = start_session(context)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, coder.id)
        question = ask(context, coder)
        {:ok, Map.merge(context, %{coder: coder.id, question: question})}
      end

      when_ "the user answers it", context do
        :ok = user_answers(context, context.question, "Yes")
        id = context.coder
        assert_receive {:agent_dispatch, ^id, _ref, message}, 2_000
        {:ok, Map.put(context, :sent, message)}
      end

      then_ "an answer offer on the question, linked to the message that carried it", context do
        assert_answer_offer(context)
      end
    end
  end

  defp ask(context, coder) do
    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}

    params = %{
      questions: [
        %{"question" => "Ship it?", "options" => [%{"label" => "Yes"}, %{"label" => "No"}]}
      ]
    }

    {:reply, reply, _} = AskUserQuestion.execute(params, frame)
    refute reply.isError, response_text(reply)
    Fixtures.question_id_from(response_text(reply))
  end

  defp assert_answer_offer(context) do
    assert context.sent =~ "Yes", "what was sent does not carry the answer: #{context.sent}"

    assert [offer] = offers(context, context.coder, %{kind: "answer"}),
           "expected one answer offer:\n" <> listing(context)

    assert offer.subject == "question:#{context.question}"
    assert offer.messages == [excerpt(context.sent)]
    {:ok, context}
  end
end
