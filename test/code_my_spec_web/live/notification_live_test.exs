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

  test "pending items appear in the pending section, resolved in recent", %{
    conn: conn,
    user: user
  } do
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

  test "list updates live when a question arrives and when it is answered", %{
    conn: conn,
    user: user
  } do
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

    # The badge lives in a stateful `LiveComponent` (`NotificationLive.Components.Dropdown`)
    # refreshed via `send_update/2` from `NotificationsHook` — a second message
    # the LiveView's own mailbox has to process after the broadcast, not a
    # synchronous assign the way a plain `handle_info` clause would be. `render/1`
    # can win the race and return before that second message lands, so this polls
    # rather than asserting once.
    eventually(fn ->
      assert view |> element(".indicator-item") |> render() =~ "2"
    end)
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        eventually(fun, deadline)
      else
        reraise(error, __STACKTRACE__)
      end
  end

  test "scrolling to the bottom of Recent loads another page", %{conn: conn, user: user} do
    ids =
      for _ <- 1..25 do
        req = create_permission(user.id)
        {:ok, _} = Notifications.resolve_permission_request(req.id, "allow")
        req.id
      end

    {:ok, view, _html} = live(conn, ~p"/app/notifications")

    initial = view |> element("#resolved-notifications") |> render()
    assert initial =~ ~s(data-more-resolved="true")
    assert count_notifications(initial) == 20

    after_scroll = render_hook(view, "load_more_resolved", %{})

    assert count_notifications(after_scroll) == 25
    assert after_scroll =~ ~s(data-more-resolved="false")
    assert Enum.all?(ids, &(after_scroll =~ &1))
  end

  defp count_notifications(html) do
    ~r/data-test="notification"/ |> Regex.scan(html) |> length()
  end

  # Was "expired question shows as expired in the inbox", setting a status
  # nothing in production could ever write. `expired` had two readers and no
  # writer; story 896 decided against building the sweeper that would have made
  # it reachable, so the status is gone and this asserts the terminal state the
  # system actually has (83309b2a).
  test "answered question shows as answered in the inbox", %{conn: conn, user: user} do
    req = create_question(user.id, "Too late?")

    {:ok, _} = CodeMySpec.Notifications.answer_question_request(req.id, %{"Too late?" => "Yes"})

    {:ok, _view, html} = live(conn, ~p"/app/notifications")
    assert html =~ "answered"
  end

  # The backlog this exists for: 224 pending tap-out rows behind ten agents,
  # 259 stale Claude Code tool prompts, and no way to clear either except one
  # page load per row. Scoped to permission requests only — `QuestionRequest`
  # stays answer-only per story 896, above.
  describe "bulk-dismissing permission requests" do
    test "a question has no checkbox to select", %{conn: conn, user: user} do
      create_question(user.id)

      {:ok, view, _html} = live(conn, ~p"/app/notifications")

      refute has_element?(view, "[data-test='select-notification']")
    end

    test "selecting all and confirming clears every pending permission request", %{
      conn: conn,
      user: user
    } do
      p1 = create_permission(user.id)
      p2 = create_permission(user.id)

      {:ok, view, _html} = live(conn, ~p"/app/notifications")

      view |> element("button", "Select all") |> render_click()
      assert has_element?(view, "[data-test='dismiss-selected']")

      # The trigger button only opens the confirm dialog via `show_confirm/2`;
      # the actual `dismiss_selected` event is pushed from the dialog's own
      # confirm button, the same as `AccountLive.Manage`'s delete flow.
      html =
        view
        |> element("#confirm-dismiss-selected [data-role='confirm-confirm']")
        |> render_click()

      assert Notifications.get_permission_request(p1.id).status == "expired"
      assert Notifications.get_permission_request(p2.id).status == "expired"
      assert html =~ "Dismissed 2 requests."
    end

    test "a question pending alongside a permission request is left alone", %{
      conn: conn,
      user: user
    } do
      question = create_question(user.id, "Still open?")
      permission = create_permission(user.id)

      {:ok, view, _html} = live(conn, ~p"/app/notifications")

      view |> element("button", "Select all") |> render_click()

      view
      |> element("#confirm-dismiss-selected [data-role='confirm-confirm']")
      |> render_click()

      assert Notifications.get_question_request(question.id).status == "pending"
      assert Notifications.get_permission_request(permission.id).status == "expired"
    end

    test "another user's request cannot be dismissed by forging its id", %{
      conn: conn,
      user: user
    } do
      other = user_fixture()
      other_permission = create_permission(other.id)
      create_permission(user.id)

      {:ok, view, _html} = live(conn, ~p"/app/notifications")

      view |> element("button", "Select all") |> render_click()

      assert Notifications.bulk_dismiss_permission_requests(
               [other_permission.id],
               user.id
             ) == 0

      assert Notifications.get_permission_request(other_permission.id).status == "pending"
    end
  end
end
