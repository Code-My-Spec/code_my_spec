defmodule CodeMySpecWeb.QuestionLiveTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Notifications

  setup :register_and_log_in_user

  defp create_question(user_id) do
    {:ok, req} =
      Notifications.create_question_request(user_id, %{
        "title" => "Pick your stack",
        "questions" => [
          %{
            "question" => "Which database?",
            "header" => "DB",
            "multiSelect" => false,
            "options" => [
              %{"label" => "Postgres", "description" => "relational"},
              %{"label" => "SQLite", "description" => "embedded"}
            ]
          },
          %{
            "question" => "Which features?",
            "header" => "Features",
            "multiSelect" => true,
            "options" => [%{"label" => "Auth"}, %{"label" => "Billing"}]
          }
        ]
      })

    req
  end

  test "renders each question with its options", %{conn: conn, user: user} do
    req = create_question(user.id)
    {:ok, _view, html} = live(conn, ~p"/app/questions/#{req.id}")

    assert html =~ "Which database?"
    assert html =~ "Postgres"
    assert html =~ "relational"
    assert html =~ "Which features?"
    assert html =~ "Auth"
    assert html =~ "Other"
  end

  test "submitting records single and multi-select answers", %{conn: conn, user: user} do
    req = create_question(user.id)
    {:ok, view, _html} = live(conn, ~p"/app/questions/#{req.id}")

    view
    |> element("form")
    |> render_submit(%{"q_0" => "Postgres", "q_1" => ["Auth", "Billing"]})

    updated = Notifications.get_question_request(req.id)
    assert updated.status == "answered"
    assert updated.answers["Which database?"] == "Postgres"
    assert updated.answers["Which features?"] == ["Auth", "Billing"]
  end

  test "an 'Other' choice resolves to the free-text value", %{conn: conn, user: user} do
    req = create_question(user.id)
    {:ok, view, _html} = live(conn, ~p"/app/questions/#{req.id}")

    view
    |> element("form")
    |> render_submit(%{"q_0" => "__other__", "q_0_other" => "CockroachDB", "q_1" => []})

    assert Notifications.get_question_request(req.id).answers["Which database?"] == "CockroachDB"
  end

  test "a question with no options renders a textarea and records the typed answer", %{conn: conn, user: user} do
    {:ok, req} =
      Notifications.create_question_request(user.id, %{
        "questions" => [%{"question" => "What should the error copy say?", "options" => []}]
      })

    {:ok, view, html} = live(conn, ~p"/app/questions/#{req.id}")
    assert html =~ "What should the error copy say?"
    assert html =~ "<textarea"

    view
    |> element("form")
    |> render_submit(%{"q_0" => "Something went wrong — please try again."})

    updated = Notifications.get_question_request(req.id)
    assert updated.status == "answered"
    assert updated.answers["What should the error copy say?"] == "Something went wrong — please try again."
  end

  test "another user's question is not shown", %{conn: conn} do
    other = user_fixture()

    {:ok, req} =
      Notifications.create_question_request(other.id, %{
        "questions" => [%{"question" => "secret?", "options" => [%{"label" => "yes"}]}]
      })

    {:ok, _view, html} = live(conn, ~p"/app/questions/#{req.id}")
    refute html =~ "secret?"
  end
end
