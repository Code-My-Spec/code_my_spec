defmodule CodeMySpecWeb.AgentConversationLive.AnAnswerReachesTheQuestionItWasGivenToTest do
  @moduledoc """
  An answer given in the cockpit settles the question whose form it was given
  in.

  The handler took the first pending question in the agent's list, so with two
  open the newer one's answer went to the older one, and its own stayed
  pending (2026-10-12).
  """
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodeMySpec.Notifications
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    agent = Fixtures.running_agent(context.scope, role: "coding")
    %{agent: agent, path: Fixtures.agent_conversation_path(context.scope, agent)}
  end

  defp ask(context, question, options) do
    {:ok, request} =
      Notifications.create_question_request(context.scope.user.id, %{
        "agent_id" => context.agent.id,
        "holder" => "user",
        "questions" => [
          %{"question" => question, "options" => Enum.map(options, &%{"label" => &1})}
        ]
      })

    request
  end

  test "the newer question's form answers the newer question", context do
    older = ask(context, "Which database?", ["Postgres", "SQLite"])
    newer = ask(context, "Move 1046 to team 2?", ["Yes", "No"])

    {:ok, view, _html} = live(context.conn, context.path)

    view
    |> form("#question-#{newer.id} [data-test='question-form']", %{"q_0" => "Yes"})
    |> render_submit()

    assert %{status: "answered", answers: %{"Move 1046 to team 2?" => "Yes"}} =
             Notifications.get_question_request(newer.id)

    assert %{status: "pending"} = Notifications.get_question_request(older.id)
  end

  test "an empty answer says so instead of claiming it was sent", context do
    request = ask(context, "Which database?", ["Postgres", "SQLite"])

    {:ok, view, _html} = live(context.conn, context.path)

    html =
      view
      |> form("#question-#{request.id} [data-test='question-form']", %{})
      |> render_submit()

    assert html =~ "Pick an option or type an answer first."
    assert %{status: "pending"} = Notifications.get_question_request(request.id)
  end
end
