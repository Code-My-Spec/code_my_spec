defmodule CodeMySpec.Notifications.AQuestionKnowsWhereItWasAskedTest do
  @moduledoc """
  A question is asked at a point in a conversation, and renders there.

  It used to render in a block pinned above the transcript, detached from the
  turn that produced it — which the conversation page's own handler argues
  against: "a question read without the work that prompted it is a question you
  cannot answer well."

  Position by timestamp was the obvious alternative and is not reliable.
  `question_requests.inserted_at` is second-resolution while
  `conversation_messages.inserted_at` carries microseconds, so a question and
  the turn that asked it land in the same second and sort either way. Rendering
  a question *before* the turn that asked it is the failure the pinned block
  already had.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Notifications

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        working_copy: "/tmp/anchor-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    %{scope: scope, agent: agent, conversation: conversation}
  end

  defp say(conversation, text) do
    {:ok, message} = Conversations.add_agent_message(conversation, "product", "assistant", text)
    message
  end

  defp ask(scope, agent, question) do
    {:ok, request} =
      Notifications.create_question_request(scope.user.id, %{
        "agent_id" => agent.id,
        "questions" => [
          %{"question" => question, "header" => nil, "multiSelect" => false, "options" => []}
        ]
      })

    request
  end

  test "it anchors to the newest turn at the time it was asked", ctx do
    _first = say(ctx.conversation, "starting on story 994")
    latest = say(ctx.conversation, "I need a decision here")

    request = ask(ctx.scope, ctx.agent, "Are open borders bilateral?")

    assert request.conversation_message_id == latest.id
  end

  # Turns that come after must not move it. The anchor is where it was asked,
  # not where the conversation currently ends.
  test "later turns do not move it", ctx do
    at = say(ctx.conversation, "asking now")
    request = ask(ctx.scope, ctx.agent, "Well?")

    say(ctx.conversation, "carried on with something else")

    assert Notifications.get_question_request(request.id).conversation_message_id == at.id
  end

  # A Claude Code session has no conversation of ours — that is the entire
  # reason `QuestionLive.Show` exists — and its questions render there.
  test "a question with no agent has no anchor", ctx do
    {:ok, request} =
      Notifications.create_question_request(ctx.scope.user.id, %{
        "questions" => [
          %{"question" => "Anyone?", "header" => nil, "multiSelect" => false, "options" => []}
        ]
      })

    assert request.conversation_message_id == nil
  end

  # An agent that has not said anything yet. Nothing to anchor to is not an
  # error — the question falls to the bottom of the chat, which is where the
  # newest thing belongs.
  test "an agent with an empty transcript still asks", ctx do
    request = ask(ctx.scope, ctx.agent, "First thing I need to know")

    assert request.conversation_message_id == nil
    assert request.status == "pending"
  end

  # The bug John hit: the tool call rendered as an ordinary tool block and no
  # form appeared under it. Nothing was wrong with the rendering — the page
  # looked questions up by `session_external_id`, which an agent never has, so
  # it found none. A session and an agent are different abstractions and a
  # question belongs to exactly one of them.
  describe "finding a conversation's questions" do
    test "an agent's questions are found by agent", ctx do
      request = ask(ctx.scope, ctx.agent, "Which theme?")

      assert [found] = Notifications.list_question_requests_for_agent(ctx.agent.id)
      assert found.id == request.id
    end

    # The column that used to be the only key. Left empty on purpose now: it
    # was always nil for an agent, and naming both implied the two identities
    # were interchangeable.
    test "an agent's question carries no session", ctx do
      request = ask(ctx.scope, ctx.agent, "Which theme?")

      assert request.session_external_id == nil
      assert Notifications.list_question_requests_for_session(nil) == []
    end

    test "one agent's questions stay out of another's", ctx do
      ask(ctx.scope, ctx.agent, "Mine")

      {:ok, other_copy} =
        CodeMySpec.WorkingCopies.issue(ctx.scope, nil,
          label: "another checkout",
          device: device_fixture(ctx.scope)
        )

      {:ok, other} =
        AgentsRepository.create_agent(ctx.scope, %{
          provider: "anthropic",
          engine: :alloy,
          role: "coding",
          working_copy: "/tmp/other-#{System.unique_integer([:positive])}",
          working_copy_id: other_copy.id
        })

      assert Notifications.list_question_requests_for_agent(other.id) == []
    end
  end

  test "an explicit anchor is not overwritten", ctx do
    first = say(ctx.conversation, "one")
    _second = say(ctx.conversation, "two")

    {:ok, request} =
      Notifications.create_question_request(ctx.scope.user.id, %{
        "agent_id" => ctx.agent.id,
        "conversation_message_id" => first.id,
        "questions" => [
          %{"question" => "Where?", "header" => nil, "multiSelect" => false, "options" => []}
        ]
      })

    assert request.conversation_message_id == first.id
  end
end
