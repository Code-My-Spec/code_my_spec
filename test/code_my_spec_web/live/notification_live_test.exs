defmodule CodeMySpecWeb.NotificationLiveTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Notifications

  setup :register_and_log_in_user

  defp create_question(user_id, question \\ "Which database?") do
    {:ok, req} =
      Notifications.create_question_request(user_id, %{
        "questions" => [%{"question" => question, "options" => []}]
      })

    req
  end

  defp create_permission(user_id) do
    {:ok, req} =
      Notifications.create_permission_request(user_id, %{
        "tool_name" => "Bash",
        "tool_input" => %{"command" => "rm -rf node_modules"}
      })

    req
  end

  test "lists pending questions and permission requests", %{conn: conn, user: user} do
    create_question(user.id)
    create_permission(user.id)

    {:ok, _view, html} = live(conn, ~p"/app/notifications")

    assert html =~ "Which database?"
    assert html =~ "Claude Code: Bash"
    assert html =~ "rm -rf node_modules"
    assert html =~ "Pending"
  end

  test "pending items appear in the pending section, resolved in recent", %{conn: conn, user: user} do
    answered = create_question(user.id, "Old question?")
    {:ok, _} = Notifications.answer_question_request(answered.id, %{"Old question?" => "yes"})
    create_question(user.id, "Fresh question?")

    {:ok, view, _html} = live(conn, ~p"/app/notifications")

    assert view |> element("section", "Pending") |> render() =~ "Fresh question?"
    assert view |> element("section", "Recent") |> render() =~ "Old question?"
    assert view |> element("section", "Recent") |> render() =~ "answered"
  end

  test "items link to their answer surfaces", %{conn: conn, user: user} do
    question = create_question(user.id)
    permission = create_permission(user.id)

    {:ok, _view, html} = live(conn, ~p"/app/notifications")

    assert html =~ ~p"/app/questions/#{question.id}"
    assert html =~ ~p"/app/permissions/#{permission.id}"
  end

  test "another user's requests are not listed", %{conn: conn} do
    other = user_fixture()
    create_question(other.id, "secret question?")

    {:ok, _view, html} = live(conn, ~p"/app/notifications")

    refute html =~ "secret question?"
  end

  test "list updates live when a question arrives and when it is answered", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/app/notifications")
    assert html =~ "Nothing here yet"

    req = create_question(user.id, "Live question?")
    assert render(view) =~ "Live question?"

    {:ok, _} = Notifications.answer_question_request(req.id, %{"Live question?" => "ok"})
    assert view |> element("section", "Recent") |> render() =~ "Live question?"
  end

  test "navbar badge shows the pending count and updates live", %{conn: conn, user: user} do
    create_question(user.id)

    {:ok, view, html} = live(conn, ~p"/app/notifications")
    assert html =~ ~s(class="indicator-item badge badge-primary badge-xs")

    create_permission(user.id)
    assert view |> element(".indicator-item") |> render() =~ "2"
  end

  test "expired question shows as expired in the inbox", %{conn: conn, user: user} do
    req = create_question(user.id, "Too late?")

    {:ok, _} =
      req
      |> CodeMySpec.Notifications.QuestionRequest.changeset(%{"status" => "expired"})
      |> CodeMySpec.Repo.update()

    {:ok, _view, html} = live(conn, ~p"/app/notifications")
    assert html =~ "expired"
  end
end
