defmodule CodeMySpec.Agents.Main.TheEscalatorHearsTheUsersAnswerTest do
  @moduledoc """
  The agent that hands a question to the user is told the user's answer, as
  well as the asker.

  Product escalated the coder's harness-auth question; John answered it and
  only the coder heard. Product's `check_answer` refused a question it had not
  asked, so the agent he expected to take the decision forward could not read
  it (2026-10-13).
  """

  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.QuestionRoutingHelpers

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    main =
      Fixtures.running_agent(context.scope, role: "main", working_copy: "/tmp/escalator-main")

    AgentPresence.present(main)
    %{main: main}
  end

  defp told?(agent_id, needle) do
    receive do
      {:agent_dispatch, ^agent_id, _ref, message} ->
        String.contains?(message, needle) or told?(agent_id, needle)

      {:work_turn_requested, ^agent_id, _ref, message} ->
        String.contains?(message, needle) or told?(agent_id, needle)
    after
      500 -> false
    end
  end

  test "main hears the answer to a question it escalated", context do
    id = ask(context, "Should QA own a tap-out raised through the deploy key?")
    _ = main_escalates(context, id, "an auth design call")
    user_answers(context, id, "Yes")

    assert told?(context.main.id, id),
           "main escalated the question and was not told the user's answer"
  end

  test "product hears the answer to a question it escalated", context do
    product =
      Fixtures.running_agent(context.scope,
        role: "product",
        working_copy: "/tmp/escalator-product"
      )

    AgentPresence.present(product)

    id = ask(context, "Should QA own a tap-out raised through the deploy key?")
    {:ok, _} = MainAgent.hand_question(context.scope, id, "product", "a product call")
    {:ok, _} = MainAgent.escalate_question(context.scope, id, "an auth design call")
    user_answers(context, id, "Yes")

    assert told?(product.id, id),
           "product escalated the question and was not told the user's answer"
  end

  test "an answer to a question nobody escalated tells only the asker", context do
    id = ask(context, "Should QA own a tap-out raised through the deploy key?")
    user_answers(context, id, "Yes")

    refute told?(context.main.id, id)
  end
end
