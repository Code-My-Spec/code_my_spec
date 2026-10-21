defmodule CodeMySpec.Notifications.APushTimeoutDoesNotFailTheAskTest do
  @moduledoc """
  WebPushElixir.send_notification/2 only matches a case on an HTTP response
  from Req.run/1; a transport failure (timeout, connection refused) comes
  back as a %Req.TransportError{} instead, which has no clause, so it raises
  (issue 8791ae67). The question it was announcing is already durable
  server-side before the push is attempted, so that raise must not reach the
  caller.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.QuestionRequest

  import CodeMySpec.UsersFixtures

  setup do
    scope = user_scope_fixture()

    {:ok, _} =
      Notifications.subscribe(scope.user.id, %{
        "endpoint" => "https://push.invalid/#{scope.user.id}",
        "p256dh_key" => "fixture",
        "auth_key" => "fixture"
      })

    :meck.new(WebPushElixir, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(WebPushElixir) end)

    %{user_id: scope.user.id}
  end

  defp questions do
    [
      %{
        "question" => "Which database?",
        "header" => "DB",
        "multiSelect" => false,
        "options" => [
          %{"label" => "Postgres", "description" => "relational"},
          %{"label" => "SQLite", "description" => "embedded"}
        ]
      }
    ]
  end

  test "a push transport timeout does not fail the ask", %{user_id: user_id} do
    # Reproduces exactly what WebPushElixir.send_notification/2 does on a
    # transport failure: its own case matches only {request, %{status: ...}},
    # so {request, %Req.TransportError{}} has no clause and raises.
    :meck.expect(WebPushElixir, :send_notification, fn _, _ ->
      raise CaseClauseError, term: {%{}, %Req.TransportError{reason: :timeout}}
    end)

    assert {:ok, %QuestionRequest{} = req} =
             Notifications.create_question_request(user_id, %{
               "title" => "Pick a DB",
               "questions" => questions()
             })

    assert req.status == "pending"
    assert Enum.map(Notifications.list_pending_notifications(user_id), & &1.id) == [req.id]
  end
end
