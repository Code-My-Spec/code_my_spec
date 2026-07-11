defmodule CodeMySpec.Notifications.InboxTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Notifications

  import CodeMySpec.UsersFixtures

  setup do
    scope = user_scope_fixture()
    %{user_id: scope.user.id}
  end

  defp question!(user_id, text \\ "Which database?") do
    {:ok, req} =
      Notifications.create_question_request(user_id, %{
        "questions" => [%{"question" => text, "options" => []}]
      })

    req
  end

  defp permission!(user_id) do
    {:ok, req} =
      Notifications.create_permission_request(user_id, %{
        "tool_name" => "Bash",
        "tool_input" => %{"command" => "mix test"}
      })

    req
  end

  describe "list_notifications/1" do
    test "returns both request types, pending before resolved", %{user_id: user_id} do
      answered = question!(user_id, "old?")
      {:ok, _} = Notifications.answer_question_request(answered.id, %{"old?" => "yes"})
      pending_q = question!(user_id, "new?")
      pending_p = permission!(user_id)

      items = Notifications.list_notifications(user_id)

      assert Enum.map(items, & &1.id) |> Enum.sort() ==
               Enum.sort([answered.id, pending_q.id, pending_p.id])

      {pending, resolved} = Enum.split_with(items, &(&1.status == "pending"))
      assert Enum.map(pending, & &1.id) |> Enum.sort() == Enum.sort([pending_q.id, pending_p.id])
      assert [%{id: resolved_id}] = resolved
      assert resolved_id == answered.id
    end

    test "excludes other users' requests", %{user_id: user_id} do
      other = user_scope_fixture()
      question!(other.user.id, "not yours")
      mine = question!(user_id)

      assert [%{id: id}] = Notifications.list_notifications(user_id)
      assert id == mine.id
    end
  end

  describe "count_pending_notifications/1" do
    test "counts pending across both types, ignoring resolved", %{user_id: user_id} do
      question!(user_id)
      permission!(user_id)
      answered = question!(user_id, "done?")
      {:ok, _} = Notifications.answer_question_request(answered.id, %{"done?" => "yep"})

      assert Notifications.count_pending_notifications(user_id) == 2
    end
  end

  describe "notification broadcasts" do
    test "create and answer broadcast on both topics", %{user_id: user_id} do
      Notifications.subscribe_notifications(user_id)
      Notifications.subscribe_notifications_list(user_id)

      req = question!(user_id)
      assert_receive {:pending_notifications_changed}
      assert_receive {:notifications_changed}

      {:ok, _} = Notifications.answer_question_request(req.id, %{"Which database?" => "pg"})
      assert_receive {:pending_notifications_changed}
      assert_receive {:notifications_changed}
    end

    test "permission create and resolve broadcast", %{user_id: user_id} do
      Notifications.subscribe_notifications(user_id)

      req = permission!(user_id)
      assert_receive {:pending_notifications_changed}

      {:ok, _} = Notifications.resolve_permission_request(req.id, "allow")
      assert_receive {:pending_notifications_changed}
    end
  end
end
