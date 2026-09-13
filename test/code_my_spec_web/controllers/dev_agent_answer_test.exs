defmodule CodeMySpecWeb.DevAgentAnswerTest do
  @moduledoc """
  Answering a named question rather than whichever one is oldest.

  `/dev/agents/:agent_id/answer` had no way to say which question it meant, so
  it answered the oldest pending one. On 2026-09-13 a caller clearing two
  questions it had just raised answered two unrelated ones belonging to another
  agent instead, and `Notifications` has no un-answer path — those answers are
  permanent. Issue `2638fbf5`.

  The refusal is the point of the test. Falling back to the oldest when the
  named question is not pending would reintroduce exactly the bug: a caller
  that named the wrong question wants to be told, not to have a different one
  answered on its behalf.
  """

  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
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
        role: "qa",
        working_copy: "/tmp/dev-answer-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope: scope, agent: agent}
  end

  defp ask(scope, agent, question) do
    {:ok, request} =
      Notifications.create_question_request(scope.user.id, %{
        "agent_id" => agent.id,
        "title" => "Claude has a question",
        "questions" => [
          %{"question" => question, "header" => nil, "multiSelect" => false, "options" => []}
        ]
      })

    request
  end

  defp status_of(agent, request_id) do
    agent.id
    |> Notifications.list_question_requests_for_agent()
    |> Enum.find(&(&1.id == request_id))
    |> Map.fetch!(:status)
  end

  describe "POST /dev/agents/:agent_id/answer" do
    test "answers the question the caller named, not the oldest one", %{
      conn: conn,
      scope: scope,
      agent: agent
    } do
      oldest = ask(scope, agent, "somebody else's question")
      mine = ask(scope, agent, "the one I raised")

      body =
        conn
        |> post(~p"/dev/agents/#{agent.id}/answer", %{
          "question_id" => mine.id,
          "answer" => "yes"
        })
        |> json_response(200)

      assert body["request_id"] == mine.id

      assert status_of(agent, mine.id) == "answered"
      assert status_of(agent, oldest.id) == "pending"
    end

    test "refuses a question that is not pending, naming the ones that are", %{
      conn: conn,
      scope: scope,
      agent: agent
    } do
      pending = ask(scope, agent, "still waiting")

      body =
        conn
        |> post(~p"/dev/agents/#{agent.id}/answer", %{
          "question_id" => Ecto.UUID.generate(),
          "answer" => "yes"
        })
        |> json_response(404)

      assert body["pending"] == [pending.id]
      assert status_of(agent, pending.id) == "pending"
    end

    test "without a question_id it still answers the oldest", %{
      conn: conn,
      scope: scope,
      agent: agent
    } do
      oldest = ask(scope, agent, "first")
      _newer = ask(scope, agent, "second")

      body =
        conn
        |> post(~p"/dev/agents/#{agent.id}/answer", %{"answer" => "yes"})
        |> json_response(200)

      assert body["request_id"] == oldest.id
    end
  end
end
